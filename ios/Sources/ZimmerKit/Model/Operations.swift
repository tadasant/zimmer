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
    /// Seconds within which Slack messages are one event; nil inherits the default, 0 is off.
    public var coalesceWindowSeconds: Int?
    public var promptTemplate: String?
    public var goal: String?
    /// The window in force: the stored one, or the default it inherits.
    public var effectiveCoalesceWindowSeconds: Int?
    /// A window stored on a trigger no Slack condition will ever read.
    public var coalesceWindowInert: Bool
    /// `skipIfPendingSession` is stored but does nothing while there is a live session to re-use.
    public var skipIfPendingSessionInert: Bool
    /// When the first of the `missedFireCount` fires was missed.
    public var firstMissedFireAt: Date?
    /// The class chosen on the trigger; nil when its sessions take the default for its conditions.
    public var schedulingClass: String?
    /// The class its sessions actually get.
    public var effectiveSchedulingClass: String?
    /// Stamped on the sessions it spawns; higher is worked first.
    public var precedence: Int?
    public var mcpServers: [String]
    public var catalogSkills: [String]
    public var catalogHooks: [String]
    public var catalogPlugins: [String]
    /// The names in the four lists above the catalog can no longer resolve, by list
    /// (`mcp_servers`, `catalog_skills`, `catalog_hooks`, `catalog_plugins`).
    public var unresolvedCatalogReferences: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case id, name, status, conditions, bursting, goal, precedence
        case effectiveCoalesceWindowSeconds = "effective_coalesce_window_seconds"
        case coalesceWindowInert = "coalesce_window_inert"
        case skipIfPendingSessionInert = "skip_if_pending_session_inert"
        case firstMissedFireAt = "first_missed_fire_at"
        case schedulingClass = "scheduling_class"
        case effectiveSchedulingClass = "effective_scheduling_class"
        case mcpServers = "mcp_servers"
        case catalogSkills = "catalog_skills"
        case catalogHooks = "catalog_hooks"
        case catalogPlugins = "catalog_plugins"
        case unresolvedCatalogReferences = "unresolved_catalog_references"
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
        case coalesceWindowSeconds = "coalesce_window_seconds"
        case promptTemplate = "prompt_template"
    }

    public init(id: Int, name: String, status: String, agentRoot: String? = nil, lastError: String? = nil,
                lastTriggeredAt: Date? = nil, lastSessionID: Int? = nil, sessionsCreated: Int? = nil, conditions: [Condition] = [],
                failedAt: Date? = nil, agentRootMissing: Bool = false, reuseSession: Bool = false, enqueueMessages: Bool = false,
                resuscitateArchived: Bool = false, skipIfPendingSession: Bool = false, missedFireCount: Int = 0,
                bursting: Bool = false, maxSessionsPerMinute: Int? = nil, coalesceWindowSeconds: Int? = nil, promptTemplate: String? = nil, goal: String? = nil,
                effectiveCoalesceWindowSeconds: Int? = nil, coalesceWindowInert: Bool = false, skipIfPendingSessionInert: Bool = false,
                firstMissedFireAt: Date? = nil, schedulingClass: String? = nil, effectiveSchedulingClass: String? = nil, precedence: Int? = nil,
                mcpServers: [String] = [], catalogSkills: [String] = [], catalogHooks: [String] = [], catalogPlugins: [String] = [],
                unresolvedCatalogReferences: [String: [String]] = [:]) {
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
        self.coalesceWindowSeconds = coalesceWindowSeconds
        self.promptTemplate = promptTemplate
        self.goal = goal
        self.effectiveCoalesceWindowSeconds = effectiveCoalesceWindowSeconds
        self.coalesceWindowInert = coalesceWindowInert
        self.skipIfPendingSessionInert = skipIfPendingSessionInert
        self.firstMissedFireAt = firstMissedFireAt
        self.schedulingClass = schedulingClass
        self.effectiveSchedulingClass = effectiveSchedulingClass
        self.precedence = precedence
        self.mcpServers = mcpServers
        self.catalogSkills = catalogSkills
        self.catalogHooks = catalogHooks
        self.catalogPlugins = catalogPlugins
        self.unresolvedCatalogReferences = unresolvedCatalogReferences
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
        coalesceWindowSeconds = try? container.decodeIfPresent(Int.self, forKey: .coalesceWindowSeconds)
        promptTemplate = try? container.decodeIfPresent(String.self, forKey: .promptTemplate)
        goal = try? container.decodeIfPresent(String.self, forKey: .goal)
        effectiveCoalesceWindowSeconds = try? container.decodeIfPresent(Int.self, forKey: .effectiveCoalesceWindowSeconds)
        coalesceWindowInert = flag(.coalesceWindowInert)
        skipIfPendingSessionInert = flag(.skipIfPendingSessionInert)
        firstMissedFireAt = try? container.decodeIfPresent(Date.self, forKey: .firstMissedFireAt)
        schedulingClass = try? container.decodeIfPresent(String.self, forKey: .schedulingClass)
        effectiveSchedulingClass = try? container.decodeIfPresent(String.self, forKey: .effectiveSchedulingClass)
        precedence = try? container.decodeIfPresent(Int.self, forKey: .precedence)
        func names(_ key: CodingKeys) -> [String] { ((try? container.decodeIfPresent([String].self, forKey: key)) ?? nil) ?? [] }
        mcpServers = names(.mcpServers)
        catalogSkills = names(.catalogSkills)
        catalogHooks = names(.catalogHooks)
        catalogPlugins = names(.catalogPlugins)
        // `{list: {name: first_seen_at}}`; only the names matter here.
        let unresolved = ((try? container.decodeIfPresent([String: [String: String]].self, forKey: .unresolvedCatalogReferences)) ?? nil) ?? [:]
        unresolvedCatalogReferences = unresolved.mapValues { Array($0.keys).sorted() }
    }

    /// Every variable a prompt template may name that a manual run can fill
    /// (`Trigger::USER_INPUT_VARIABLES`, in its order); `{{time}}` and `{{date}}` fill themselves.
    public static let userInputVariables = [
        "link", "text", "author", "channel", "event", "repo", "number", "title", "labels",
        "channel_id", "message_ts", "thread_ts", "author_id", "chat_id", "message_id", "thread_id",
    ]

    /// The web form's hint under each variable's field (`TriggersHelper::VARIABLE_PLACEHOLDERS`).
    public static func placeholder(for variable: String) -> String {
        switch variable {
        case "link": return "e.g. https://example.com/message/123"
        case "text": return "e.g. The message content…"
        case "author": return "e.g. Jane Doe"
        case "channel": return "e.g. #general"
        case "event": return "e.g. Session #5 needs input"
        case "repo": return "e.g. tadasant/zimmer"
        case "number": return "e.g. 177"
        case "title": return "e.g. Fix the flaky poller test"
        case "labels": return "e.g. ready to merge"
        case "channel_id": return "e.g. C0A6BF8T45R"
        case "message_ts": return "e.g. 1704067300.000100"
        case "thread_ts": return "e.g. 1704067000.000100"
        case "author_id": return "e.g. U0123ABCD"
        default: return ""
        }
    }

    /// The variables this trigger's template names that a run by hand can fill, in the order
    /// the web form lists them (`Trigger#prompt_variables`). `{{name}}` and `{{name|untrusted}}`
    /// both count; any other `{{…}}` is not a variable.
    public var promptVariables: [String] {
        guard let template = promptTemplate else { return [] }
        let named = Set(Self.placeholderNames(in: template))
        return Self.userInputVariables.filter { named.contains($0) }
    }

    static func placeholderNames(in template: String) -> [String] {
        var names: [String] = []
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "}}") else { break }
            let inside = rest[..<close.lowerBound]
            let parts = inside.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            // The server substitutes a bare name or `|untrusted` and nothing else, so a
            // placeholder with any other filter is text, not a variable to ask for.
            if parts.count == 2, parts[1] != "untrusted" { continue }
            names.append(String(parts[0]))
            rest = rest[close.upperBound...]
        }
        return names
    }

    /// A catalog name as the web page prints it, flagged when the catalog no longer has it.
    public func catalogReferenceUnresolved(_ list: String, _ name: String) -> Bool {
        unresolvedCatalogReferences[list]?.contains(name) ?? false
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
        if coalesceWindowSeconds == 0 { badges.append("No coalescing") }
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
    /// moment of the last in `calendar`'s zone, as the web UI reads its two dates. The API
    /// parses bare dates as midnight, which would drop the last day, so the bounds go as
    /// timestamps — written in UTC, so no offset's sign has to survive the query string.
    public func query(calendar: Calendar = .current) -> [String: String] {
        switch self {
        case let .days(days):
            return ["days": String(min(max(days, 1), Self.maxDays))]
        case let .range(from, to):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(identifier: "UTC")
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
