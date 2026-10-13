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
        /// When this condition, rather than another of the trigger's, last fired it.
        public var lastTriggeredAt: Date?

        enum CodingKeys: String, CodingKey {
            case description
            case type = "condition_type"
            case lastTriggeredAt = "last_triggered_at"
        }

        public init(type: String?, description: String?, lastTriggeredAt: Date? = nil) {
            self.type = type
            self.description = description
            self.lastTriggeredAt = lastTriggeredAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            description = try? container.decodeIfPresent(String.self, forKey: .description)
            lastTriggeredAt = try? container.decodeIfPresent(Date.self, forKey: .lastTriggeredAt)
        }

        /// The web page's badge for the type (`TriggersHelper::CONDITION_TYPE_BADGES`).
        public var label: String {
            switch type {
            case "slack": return "Slack"
            case "schedule": return "Schedule"
            case "ao_event": return "Zimmer Event"
            case "github_label", "github_issue": return "GitHub"
            case "system_event": return "System Event"
            case "whatsapp": return "WhatsApp"
            case "email": return "Email"
            case let other?: return other.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
            case nil: return "Condition"
            }
        }

        /// What the badge leaves for the line beside it: the description opens with the
        /// badge's words ("Slack: …"), so they are not printed twice.
        public var detail: String {
            let text = description ?? ""
            let prefix = "\(label): "
            return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
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
    /// When it failed to fire, for a trigger in the `failed` status.
    public var failedAt: Date?
    /// The catalog has no root under `agentRoot`: the trigger is saved and every fire that
    /// has to spawn a session fails until the name resolves.
    public var agentRootMissing: Bool
    /// Fires go to the session it last started rather than a new one.
    public var reuseSession: Bool
    /// With `reuseSession`: a fire while that session is running is queued, not dropped.
    public var enqueueMessages: Bool
    /// With `reuseSession`: a fire while that session is archived unarchives it.
    public var resuscitateArchived: Bool
    /// A fire spawns nothing while a session it started is still waiting or running.
    public var skipIfPendingSession: Bool
    /// Scheduled runs the re-used session has not taken yet.
    public var missedFireCount: Int
    /// Over its sessions-per-minute cap: spawns are suppressed until the burst subsides.
    public var bursting: Bool
    public var maxSessionsPerMinute: Int?
    public var promptTemplate: String?
    public var goal: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conditions, bursting, goal
        case agentRoot = "agent_root_name"
        case lastError = "last_error"
        case lastTriggeredAt = "last_triggered_at"
        case lastSessionID = "last_session_id"
        case sessionsCreated = "sessions_created_count"
        case failedAt = "failed_at"
        case agentRootMissing = "agent_root_missing_from_catalog"
        case reuseSession = "reuse_session"
        case enqueueMessages = "enqueue_messages"
        case resuscitateArchived = "resuscitate_archived"
        case skipIfPendingSession = "skip_if_pending_session"
        case missedFireCount = "missed_fire_count"
        case maxSessionsPerMinute = "max_sessions_per_minute"
        case promptTemplate = "prompt_template"
    }

    public init(id: Int, name: String, status: String, agentRoot: String? = nil, lastError: String? = nil,
                lastTriggeredAt: Date? = nil, lastSessionID: Int? = nil, sessionsCreated: Int? = nil, conditions: [Condition] = [],
                failedAt: Date? = nil, agentRootMissing: Bool = false, reuseSession: Bool = false, enqueueMessages: Bool = false,
                resuscitateArchived: Bool = false, skipIfPendingSession: Bool = false, missedFireCount: Int = 0,
                bursting: Bool = false, maxSessionsPerMinute: Int? = nil, promptTemplate: String? = nil, goal: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.agentRoot = agentRoot
        self.lastError = lastError
        self.lastTriggeredAt = lastTriggeredAt
        self.lastSessionID = lastSessionID
        self.sessionsCreated = sessionsCreated
        self.conditions = conditions
        self.failedAt = failedAt
        self.agentRootMissing = agentRootMissing
        self.reuseSession = reuseSession
        self.enqueueMessages = enqueueMessages
        self.resuscitateArchived = resuscitateArchived
        self.skipIfPendingSession = skipIfPendingSession
        self.missedFireCount = missedFireCount
        self.bursting = bursting
        self.maxSessionsPerMinute = maxSessionsPerMinute
        self.promptTemplate = promptTemplate
        self.goal = goal
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
        failedAt = try? container.decodeIfPresent(Date.self, forKey: .failedAt)
        func flag(_ key: CodingKeys) -> Bool { ((try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? false }
        agentRootMissing = flag(.agentRootMissing)
        reuseSession = flag(.reuseSession)
        enqueueMessages = flag(.enqueueMessages)
        resuscitateArchived = flag(.resuscitateArchived)
        skipIfPendingSession = flag(.skipIfPendingSession)
        bursting = flag(.bursting)
        missedFireCount = ((try? container.decodeIfPresent(Int.self, forKey: .missedFireCount)) ?? nil) ?? 0
        maxSessionsPerMinute = try? container.decodeIfPresent(Int.self, forKey: .maxSessionsPerMinute)
        promptTemplate = try? container.decodeIfPresent(String.self, forKey: .promptTemplate)
        goal = try? container.decodeIfPresent(String.self, forKey: .goal)
    }

    public var isEnabled: Bool { status == "enabled" }
    public var isFailed: Bool { status == "failed" }

    /// The web UI's button for the status toggle: a failed trigger is re-armed, not enabled.
    public var toggleLabel: String {
        if isEnabled { return "Turn Off" }
        return isFailed ? "Re-arm" : "Turn On"
    }

    /// The small labels beside the name on the web UI's trigger page, in its order.
    public var badges: [String] {
        var badges: [String] = []
        if reuseSession { badges.append("Re-uses session") }
        if enqueueMessages { badges.append("Enqueues messages") }
        if resuscitateArchived { badges.append("Resuscitates archived") }
        if skipIfPendingSession { badges.append("Skips while pending") }
        if missedFireCount > 0 { badges.append(missedFireCount == 1 ? "1 missed fire" : "\(missedFireCount) missed fires") }
        if bursting { badges.append("Bursting") }
        return badges
    }
}

/// A trigger's page (`GET /api/v1/triggers/:id`): the trigger and the sessions it last made.
public struct TriggerDetail: Hashable, Sendable, Decodable {
    public struct RecentSession: Hashable, Sendable, Decodable, Identifiable {
        public var id: Int
        public var title: String?
        public var status: SessionStatus?
        public var createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, title, status
            case createdAt = "created_at"
        }

        public init(id: Int, title: String? = nil, status: SessionStatus? = nil, createdAt: Date? = nil) {
            self.id = id
            self.title = title
            self.status = status
            self.createdAt = createdAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            status = try? container.decodeIfPresent(SessionStatus.self, forKey: .status)
            createdAt = try? container.decodeIfPresent(Date.self, forKey: .createdAt)
        }
    }

    public var trigger: TriggerSummary
    /// Newest first, ten at most.
    public var recentSessions: [RecentSession]

    enum CodingKeys: String, CodingKey {
        case trigger
        case recentSessions = "recent_sessions"
    }

    public init(trigger: TriggerSummary, recentSessions: [RecentSession] = []) {
        self.trigger = trigger
        self.recentSessions = recentSessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try container.decode(TriggerSummary.self, forKey: .trigger)
        recentSessions = (try? container.decodeIfPresent([RecentSession].self, forKey: .recentSessions)) ?? []
    }
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

    /// The toast: the web UI's Invoke tells these apart, and so does this — only a session
    /// that was actually started reads as a plain success.
    public var notice: String {
        switch outcome {
        case .started: return message
        case .burstNotice: return "Burst: no new session. \(message)"
        case .pendingSession: return "A session is still pending. \(message)"
        case .notReusable: return "Its session cannot take another turn. \(message)"
        }
    }
}

/// The window a Costs view covers, as the web UI's picker offers it: a one-tap horizon, or a
/// range of calendar days off a calendar.
public enum CostWindow: Hashable, Sendable {
    /// The last `days` days, up to now.
    case days(Int)
    /// Whole calendar days, both ends included, in the phone's time zone.
    case range(from: Date, to: Date)

    /// One of the web UI's horizons, with the short label a segmented control has room for.
    public struct Preset: Hashable, Sendable, Identifiable {
        public var days: Int
        public var label: String
        public var id: Int { days }
    }

    /// The web UI's horizons (`CostWindow::PRESETS`), in its order.
    public static let presets: [Preset] = [
        Preset(days: 1, label: "24h"), Preset(days: 7, label: "7d"), Preset(days: 30, label: "30d"),
        Preset(days: 90, label: "90d"), Preset(days: 365, label: "1y"),
    ]

    /// The most a window spans: the server's own cap on `days`.
    public static let maxDays = 365

    /// A calendar range as the web UI's form resolves one: the ends swapped if they are the
    /// wrong way round, and a span over a year clamped to the year ending on `to` rather
    /// than refused.
    public static func custom(from: Date, to: Date, calendar: Calendar = .current) -> CostWindow {
        var start = calendar.startOfDay(for: from)
        var end = calendar.startOfDay(for: to)
        if start > end { swap(&start, &end) }
        if let earliest = calendar.date(byAdding: .day, value: -(maxDays - 1), to: end), start < earliest { start = earliest }
        return .range(from: start, to: end)
    }

    public var isCustom: Bool {
        if case .range = self { return true }
        return false
    }

    /// `days`, or `from` and `to` as instants: the start of the first day and the last
    /// moment of the last, as the web UI reads its two dates. The API parses bare dates as
    /// midnight, which would drop the last day, so the bounds go as timestamps.
    public func query(calendar: Calendar = .current) -> [String: String] {
        switch self {
        case let .days(days):
            return ["days": String(min(max(days, 1), Self.maxDays))]
        case let .range(from, to):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = calendar.timeZone
            let start = calendar.startOfDay(for: from)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
            return ["from": formatter.string(from: start), "to": formatter.string(from: nextDay.addingTimeInterval(-0.001))]
        }
    }

    /// What the window reads as: the web UI's preset names, or "Aug 1 – Aug 3, 2026".
    public func label(calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch self {
        case let .days(days):
            switch days {
            case 1: return "24 hours"
            case 365: return "1 year"
            default: return "\(days) days"
            }
        case let .range(from, to):
            let full = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day().year()
            if calendar.isDate(from, inSameDayAs: to) { return from.formatted(full) }
            let short = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
            return "\(from.formatted(short)) – \(to.formatted(full))"
        }
    }
}

/// Which slice of the ledger a Costs view is about, as the web UI's drilldown narrows it:
/// the whole fleet, one agent root, or one session.
public enum CostScope: Hashable, Sendable {
    case fleet
    case agentRoot(String)
    case session(Int)

    public var isFleet: Bool { self == .fleet }

    /// `agent_root` or `session_id`; nothing for the fleet.
    public var query: [String: String] {
        switch self {
        case .fleet: return [:]
        case let .agentRoot(root): return ["agent_root": root]
        case let .session(id): return ["session_id": String(id)]
        }
    }

    /// The by-root row that narrows to itself. Not the folded "other (N)" bucket, which is
    /// several roots at once and so not one thing to narrow to.
    public static func narrowable(agentRoot: String) -> Bool { !agentRoot.hasPrefix("other (") }
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
        public var title: String?
        public var apiCalls: Int?
        public var id: Int { sessionID }

        enum CodingKeys: String, CodingKey {
            case tokens, title
            case sessionID = "session_id"
            case costUSD = "cost_usd"
            case apiCalls = "api_calls"
        }

        public init(sessionID: Int, costUSD: Double, tokens: Int? = nil, title: String? = nil, apiCalls: Int? = nil) {
            self.sessionID = sessionID
            self.costUSD = costUSD
            self.tokens = tokens
            self.title = title
            self.apiCalls = apiCalls
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decode(Int.self, forKey: .sessionID)
            costUSD = try container.decode(Double.self, forKey: .costUSD)
            tokens = try? container.decodeIfPresent(Int.self, forKey: .tokens)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            apiCalls = try? container.decodeIfPresent(Int.self, forKey: .apiCalls)
        }
    }

    public var from: Date?
    public var to: Date?
    /// The slice the server computed over, as it read the request.
    public var scope: CostScope
    public var totalUSD: Double
    public var days: [Day]
    public var agentRoots: [Row]
    public var models: [Row]
    public var topSessions: [TopSession]

    public init(from: Date? = nil, to: Date? = nil, scope: CostScope = .fleet, totalUSD: Double, days: [Day] = [], agentRoots: [Row] = [],
                models: [Row] = [], topSessions: [TopSession] = []) {
        self.from = from
        self.to = to
        self.scope = scope
        self.totalUSD = totalUSD
        self.days = days
        self.agentRoots = agentRoots
        self.models = models
        self.topSessions = topSessions
    }

    enum CodingKeys: String, CodingKey {
        case window, totals, scope
        case days = "by_day"
        case agentRoots = "by_agent_root"
        case models = "by_model"
        case topSessions = "top_sessions"
    }

    struct Window: Decodable { let from: Date?; let to: Date? }
    struct Scope: Decodable { let agent_root: String?; let session_id: Int? }
    struct Totals: Decodable {
        let cost_usd: Double?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let window = try? container.decodeIfPresent(Window.self, forKey: .window)
        from = window?.from
        to = window?.to
        // `session_id` wins when both are set, as the server narrows.
        let scope = (try? container.decodeIfPresent(Scope.self, forKey: .scope)) ?? nil
        if let session = scope?.session_id {
            self.scope = .session(session)
        } else if let root = scope?.agent_root {
            self.scope = .agentRoot(root)
        } else {
            self.scope = .fleet
        }
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
        else { throw ZimmerError.decoding("health report: no health_report key") }

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
