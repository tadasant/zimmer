import Foundation

/// What the web UI's trigger form writes (`POST /api/v1/triggers`, `PATCH /api/v1/triggers/:id`):
/// the trigger's own settings and its conditions, each condition's configuration holding only
/// the keys the form has a field for, as the web form's hidden inputs are disabled so a type
/// switch leaves no stale keys behind. Every parameter the API permits has a place here; the
/// two re-use switches are optional because the app's form leaves them alone (#1318).
public struct TriggerDraft: Hashable, Sendable {
    public var name: String
    /// `enabled` or `disabled`; nil leaves the status alone (a new trigger starts enabled).
    public var status: String?
    public var agentRootName: String
    public var promptTemplate: String
    public var goal: String
    public var reuseSession: Bool
    /// nil is not sent: the switch is on the trigger's web page.
    public var enqueueMessages: Bool?
    public var resuscitateArchived: Bool?
    /// A session to re-use from the start, with `reuseSession`.
    public var lastSessionID: Int?
    /// nil is no limit.
    public var maxSessionsPerMinute: Int?
    public var skipIfPendingSession: Bool
    /// nil inherits the default; 0 turns coalescing off.
    public var coalesceWindowSeconds: Int?
    /// `priority`, `spot`, or nil for the default its conditions give.
    public var schedulingClass: String?
    /// nil predefines nothing.
    public var precedence: Int?
    public var mcpServers: [String]
    public var catalogSkills: [String]
    public var catalogHooks: [String]
    public var catalogPlugins: [String]
    public var conditions: [ConditionDraft]
    /// Persisted conditions to remove, sent as `_destroy`.
    public var removedConditionIDs: [Int]

    public init(name: String = "", status: String? = nil, agentRootName: String = "", promptTemplate: String = "", goal: String = "",
                reuseSession: Bool = false, enqueueMessages: Bool? = nil, resuscitateArchived: Bool? = nil, lastSessionID: Int? = nil,
                maxSessionsPerMinute: Int? = nil, skipIfPendingSession: Bool = false, coalesceWindowSeconds: Int? = nil,
                schedulingClass: String? = nil, precedence: Int? = nil, mcpServers: [String] = [], catalogSkills: [String] = [],
                catalogHooks: [String] = [], catalogPlugins: [String] = [], conditions: [ConditionDraft] = [], removedConditionIDs: [Int] = []) {
        self.name = name
        self.status = status
        self.agentRootName = agentRootName
        self.promptTemplate = promptTemplate
        self.goal = goal
        self.reuseSession = reuseSession
        self.enqueueMessages = enqueueMessages
        self.resuscitateArchived = resuscitateArchived
        self.lastSessionID = lastSessionID
        self.maxSessionsPerMinute = maxSessionsPerMinute
        self.skipIfPendingSession = skipIfPendingSession
        self.coalesceWindowSeconds = coalesceWindowSeconds
        self.schedulingClass = schedulingClass
        self.precedence = precedence
        self.mcpServers = mcpServers
        self.catalogSkills = catalogSkills
        self.catalogHooks = catalogHooks
        self.catalogPlugins = catalogPlugins
        self.conditions = conditions
        self.removedConditionIDs = removedConditionIDs
    }

    /// The form as the web's edit page opens it: the trigger's stored settings and conditions.
    public init(editing trigger: TriggerSummary) {
        self.init(
            name: trigger.name, agentRootName: trigger.agentRoot ?? "", promptTemplate: trigger.promptTemplate ?? "",
            goal: trigger.goal ?? "", reuseSession: trigger.reuseSession, lastSessionID: nil,
            maxSessionsPerMinute: trigger.maxSessionsPerMinute, skipIfPendingSession: trigger.skipIfPendingSession,
            coalesceWindowSeconds: trigger.coalesceWindowSeconds, schedulingClass: trigger.schedulingClass,
            precedence: trigger.precedence, mcpServers: trigger.mcpServers, catalogSkills: trigger.catalogSkills,
            catalogHooks: trigger.catalogHooks, catalogPlugins: trigger.catalogPlugins,
            conditions: trigger.conditions.map(ConditionDraft.init(condition:))
        )
    }

    /// The web's new-trigger page: one Slack condition to fill in.
    public static func blank() -> TriggerDraft {
        TriggerDraft(conditions: [ConditionDraft(type: "slack")])
    }

    /// The catalog lists, keyed as `NewSessionRequest` keys them.
    public var selections: [CatalogKind: [String]] {
        get { [.mcpServers: mcpServers, .skills: catalogSkills, .hooks: catalogHooks, .plugins: catalogPlugins] }
        set {
            mcpServers = newValue[.mcpServers] ?? []
            catalogSkills = newValue[.skills] ?? []
            catalogHooks = newValue[.hooks] ?? []
            catalogPlugins = newValue[.plugins] ?? []
        }
    }

    /// Whether any condition is a Slack one: the coalescing window is read on no other.
    public var hasSlackCondition: Bool { conditions.contains { $0.type == "slack" } }

    /// The request body, with the API's parameter names. A blank number is `null`, as the
    /// web's empty number field amounts to; an omitted re-use switch is left out.
    public var body: [String: Any] {
        var json: [String: Any] = [
            "name": name,
            "agent_root_name": agentRootName,
            "prompt_template": promptTemplate,
            "goal": goal,
            "reuse_session": reuseSession,
            "skip_if_pending_session": skipIfPendingSession,
            "max_sessions_per_minute": maxSessionsPerMinute.map { $0 as Any } ?? NSNull(),
            "coalesce_window_seconds": coalesceWindowSeconds.map { $0 as Any } ?? NSNull(),
            "scheduling_class": schedulingClass.map { $0 as Any } ?? NSNull(),
            "precedence": precedence.map { $0 as Any } ?? NSNull(),
            "mcp_servers": mcpServers,
            "catalog_skills": catalogSkills,
            "catalog_hooks": catalogHooks,
            "catalog_plugins": catalogPlugins,
            "trigger_conditions_attributes": conditions.map(\.body) + removedConditionIDs.map { ["id": $0, "_destroy": "1"] as [String: Any] },
        ]
        if let status { json["status"] = status }
        if let enqueueMessages { json["enqueue_messages"] = enqueueMessages }
        if let resuscitateArchived { json["resuscitate_archived"] = resuscitateArchived }
        if let lastSessionID { json["last_session_id"] = lastSessionID }
        return json
    }
}

/// One condition card of the form. `configuration` holds every key the form can write; which
/// of them go in the request depends on `type`, as the web form disables the inputs of the
/// types it is not showing.
public struct ConditionDraft: Hashable, Sendable, Identifiable {
    public enum ScheduleMode: String, Hashable, Sendable, CaseIterable {
        case recurring, oneTime
    }

    /// The card's identity in the form; `serverID` is the persisted condition's.
    public let id: UUID
    public var serverID: Int?
    /// One of `ConditionDraft.types`; "" until chosen.
    public var type: String
    public var scheduleMode: ScheduleMode
    public var configuration: ConditionConfiguration

    public init(id: UUID = UUID(), serverID: Int? = nil, type: String, scheduleMode: ScheduleMode? = nil, configuration: ConditionConfiguration = ConditionConfiguration()) {
        self.id = id
        self.serverID = serverID
        self.type = type
        self.scheduleMode = scheduleMode ?? (configuration.scheduledAt.isEmpty ? .recurring : .oneTime)
        self.configuration = configuration
    }

    public init(condition: TriggerSummary.Condition) {
        self.init(serverID: condition.id, type: condition.type ?? "", configuration: condition.configuration)
    }

    /// The condition types, with the web form's labels, in its order.
    public static let types: [(id: String, label: String)] = [
        ("slack", "Slack - Channel messages or @mentions"),
        ("whatsapp", "WhatsApp - Messages in a chat"),
        ("email", "Email - New mail in a mailbox"),
        ("schedule", "Schedule - Time-based (recurring or one-time)"),
        ("ao_event", "Zimmer Event - Internal system event"),
        ("system_event", "System Event - The deployment changed state"),
        ("github_label", "GitHub Label - A label is added to a PR or issue"),
        ("github_issue", "GitHub Issue - A new issue is opened"),
    ]

    public static let slackEventTypes: [(id: String, label: String)] = [
        ("new_message", "New message - All messages in channel"),
        ("bot_mention", "Bot mention - @mentions and DMs from allowed users"),
        ("dm_message", "Direct message - Any DM to Zimmer (allow-list applies)"),
        ("passive_listen_thread", "Passive listen: threads - Replies in threads Zimmer has joined, no @mention needed"),
        ("passive_listen_channel", "Passive listen: channels - Messages in channels Zimmer posted in recently"),
    ]

    public static let scheduleUnits = ["minutes", "hours", "days", "weeks"]
    public static let daysOfWeek = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    public static let zimmerEvents: [(id: String, label: String)] = [
        ("session_needs_input", "Session transitions to needs_input"),
        ("session_failed", "Session transitions to failed"),
        ("session_archived", "Session archived"),
        ("account_needs_reauth", "Account needs re-authentication"),
    ]

    public static let systemEvents: [(id: String, label: String)] = [
        ("quota_available", "Quota available again (the account pool recovered)"),
        ("no_sessions_in_progress", "Fleet has room for more work (few enough sessions running — rate-limited; tune on /inference)"),
    ]

    public static let githubTargets: [(id: String, label: String)] = [("pull_request", "Pull requests"), ("issue", "Issues")]

    public static let whatsappModes: [(id: String, label: String)] = [
        ("listen", "Listen - every new message"),
        ("addressed", "Addressed - only when someone @mentions, replies to, or names Zimmer"),
    ]

    /// Whether the Slack channel field is shown: a DM condition watches DMs and never a channel.
    public var showsSlackChannel: Bool { configuration.eventType != "dm_message" }
    /// Units whose schedule names a time of day (and so a time zone).
    public var showsTime: Bool { ["days", "weeks"].contains(configuration.unit) }
    public var showsDayOfWeek: Bool { configuration.unit == "weeks" }

    /// The web's `condition_json` shape for a write: the type, the persisted id, and only the
    /// configuration keys the chosen type's fields hold.
    public var body: [String: Any] {
        var json: [String: Any] = ["condition_type": type, "configuration": configurationBody]
        if let serverID { json["id"] = serverID }
        return json
    }

    var configurationBody: [String: Any] {
        let c = configuration
        switch type {
        case "slack":
            // A DM condition's channel is blanked, not merely hidden, as the web form does.
            var json: [String: Any] = [
                "channel_id": showsSlackChannel ? c.channelID : "",
                "channel_name": showsSlackChannel ? c.channelName : "",
                "event_type": c.eventType,
                "thread_ts": c.threadTS,
            ]
            if !c.allowedUserIDs.isEmpty { json["allowed_user_ids"] = c.allowedUserIDs }
            return json
        case "whatsapp":
            return ["chat_id": c.chatID, "chat_name": c.chatName, "mode": c.mode, "keywords": c.keywords, "include_from_me": c.includeFromMe]
        case "email":
            return ["query": c.query, "include_automated": c.includeAutomated]
        case "schedule":
            switch scheduleMode {
            case .oneTime:
                return ["scheduled_at": c.scheduledAt, "timezone": c.timezone]
            case .recurring:
                var json: [String: Any] = ["interval": Int(c.interval).map { $0 as Any } ?? c.interval, "unit": c.unit]
                if showsTime { json["time"] = c.time; json["timezone"] = c.timezone }
                if showsDayOfWeek { json["day_of_week"] = c.dayOfWeek }
                return json
            }
        case "ao_event":
            var json: [String: Any] = ["event_name": c.eventName]
            if !c.watchedSessionID.isEmpty { json["watched_session_id"] = c.watchedSessionID }
            return json
        case "system_event":
            return ["event_name": c.eventName]
        case "github_label":
            return ["repos": c.repos, "target": c.target, "labels": c.labels]
        case "github_issue":
            return ["repos": c.repos, "exclude_labels": c.excludeLabels]
        default:
            return [:]
        }
    }

    /// The line the server writes for the condition (`TriggerCondition#description`), so an
    /// in-memory Zimmer lists what the real one would.
    public var description: String {
        let c = configuration
        switch type {
        case "slack":
            let channel = c.channelName.isEmpty ? c.channelID : c.channelName
            switch c.eventType {
            case "bot_mention":
                if !c.threadTS.isEmpty, !c.channelID.isEmpty { return "Slack: @mention in thread \(c.threadTS) of #\(channel)" }
                return c.channelName.isEmpty ? "Slack: @mention in all channels + DMs" : "Slack: @mention in #\(c.channelName) + DMs"
            case "dm_message":
                return c.allowedUserIDs.isEmpty ? "Slack: DMs to Zimmer" : "Slack: DMs to Zimmer from \(c.allowedUserIDs.count) allowed user(s)"
            case "passive_listen_thread":
                return "Slack: replies in threads Zimmer joined, \(c.channelName.isEmpty ? "in all channels" : "in #\(c.channelName)")"
            case "passive_listen_channel":
                return "Slack: messages in \(c.channelName.isEmpty ? "all channels" : "#\(c.channelName)") Zimmer posted in recently"
            default:
                return c.channelName.isEmpty ? "Slack trigger" : "Slack: #\(c.channelName)"
            }
        case "whatsapp":
            let chat = c.chatName.isEmpty ? (c.chatID.isEmpty ? "(no chat)" : c.chatID) : c.chatName
            return c.mode == "addressed" ? "WhatsApp: messages addressing Zimmer in \(chat)" : "WhatsApp: every message in \(chat)"
        case "email":
            return "Email: new mail matching \(c.query.isEmpty ? "in:inbox" : c.query)\(c.includeAutomated ? ", automated mail included" : "")"
        case "schedule":
            if scheduleMode == .oneTime { return "Once at \(c.scheduledAt.replacingOccurrences(of: "T", with: " ")) (\(c.timezone))" }
            let interval = Int(c.interval) ?? 0
            let unit = c.unit
            let base = interval == 1 ? "Every \(String(unit.dropLast()))" : "Every \(interval) \(unit)"
            switch unit {
            case "minutes": return base
            case "hours": return c.time.isEmpty ? base : "\(base) at :\(c.time.split(separator: ":").last.map(String.init) ?? "00")"
            case "days": return "\(base)\(c.time.isEmpty ? "" : " at \(c.time)") (\(c.timezone))"
            case "weeks": return "\(base)\(c.dayOfWeek.isEmpty ? "" : " on \(c.dayOfWeek.capitalized)")\(c.time.isEmpty ? "" : " at \(c.time)") (\(c.timezone))"
            default: return "Custom schedule"
            }
        case "ao_event":
            let base: String
            switch c.eventName {
            case "session_needs_input": base = "Zimmer Event: Session needs input"
            case "session_failed": base = "Zimmer Event: Session failed"
            case "session_archived": base = "Zimmer Event: Session archived"
            case "account_needs_reauth": base = "Zimmer Event: Account needs re-authentication"
            default: base = "Zimmer Event: \(c.eventName)"
            }
            return c.watchedSessionID.isEmpty ? base : "\(base) (session #\(c.watchedSessionID))"
        case "system_event":
            switch c.eventName {
            case "quota_available": return "System Event: Quota available again"
            case "no_sessions_in_progress": return "System Event: Fleet has room for more work"
            default: return "System Event: \(c.eventName)"
            }
        case "github_label":
            let quoted = c.labels.map { "'\($0)'" }.joined(separator: " or ")
            return "GitHub: \(quoted.isEmpty ? "(no labels)" : quoted) added to \(c.target == "issue" ? "issues" : "PRs") in \(reposSummary)"
        case "github_issue":
            let excluded = c.excludeLabels.map { "'\($0)'" }.joined(separator: " or ")
            let base = "GitHub: new issue in \(reposSummary)"
            return excluded.isEmpty ? base : "\(base), unless labelled \(excluded)"
        default:
            return "Unknown trigger"
        }
    }

    private var reposSummary: String {
        let repos = configuration.repos
        if repos.isEmpty { return "(no repos)" }
        if repos.count <= 2 { return repos.joined(separator: ", ") }
        return "\(repos[0]), \(repos[1]) +\(repos.count - 2) more"
    }
}

/// A condition's `configuration` as the form reads and writes it: every key the web form has
/// a field for, read leniently (the server stores what the web posted, so a number may be a
/// string, a list a newline-joined string, a flag "1"). The poller's own keys are not here;
/// the server merges them back on an edit.
public struct ConditionConfiguration: Hashable, Sendable, Decodable {
    // Slack
    public var channelID = ""
    public var channelName = ""
    public var eventType = "new_message"
    public var threadTS = ""
    public var allowedUserIDs: [String] = []
    // Schedule
    public var interval = "1"
    public var unit = ""
    public var time = ""
    public var dayOfWeek = ""
    public var timezone = "UTC"
    public var scheduledAt = ""
    // Zimmer and system events
    public var eventName = ""
    public var watchedSessionID = ""
    // GitHub
    public var repos: [String] = []
    public var target = "pull_request"
    public var labels: [String] = []
    public var excludeLabels: [String] = []
    // WhatsApp
    public var chatID = ""
    public var chatName = ""
    public var mode = "listen"
    public var keywords: [String] = []
    public var includeFromMe = false
    // Email
    public var query = ""
    public var includeAutomated = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let raw = try [String: LooseJSON](from: decoder)
        func text(_ key: String) -> String? { raw[key]?.text }
        func list(_ key: String) -> [String] { raw[key]?.lines ?? [] }
        channelID = text("channel_id") ?? ""
        channelName = text("channel_name") ?? ""
        eventType = text("event_type") ?? "new_message"
        threadTS = text("thread_ts") ?? ""
        allowedUserIDs = list("allowed_user_ids")
        interval = text("interval") ?? "1"
        unit = text("unit") ?? ""
        time = text("time") ?? ""
        dayOfWeek = text("day_of_week") ?? ""
        timezone = text("timezone") ?? "UTC"
        scheduledAt = text("scheduled_at") ?? ""
        eventName = text("event_name") ?? ""
        watchedSessionID = text("watched_session_id") ?? ""
        repos = list("repos")
        target = text("target") ?? "pull_request"
        labels = list("labels")
        excludeLabels = list("exclude_labels")
        chatID = text("chat_id") ?? ""
        chatName = text("chat_name") ?? ""
        mode = text("mode") ?? "listen"
        keywords = list("keywords")
        includeFromMe = raw["include_from_me"]?.flag ?? false
        query = text("query") ?? ""
        includeAutomated = raw["include_automated"]?.flag ?? false
    }
}

/// A JSON value read without knowing its type ahead: the configuration hash is whatever the
/// form, the API or an agent wrote.
public enum LooseJSON: Hashable, Sendable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([LooseJSON])
    case null
    case object

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let flag = try? container.decode(Bool.self) { self = .bool(flag); return }
        if let number = try? container.decode(Double.self) { self = .number(number); return }
        if let text = try? container.decode(String.self) { self = .string(text); return }
        if let list = try? container.decode([LooseJSON].self) { self = .list(list); return }
        self = .object
    }

    /// The value as the form's text field would hold it.
    public var text: String? {
        switch self {
        case let .string(text): return text
        case let .number(number): return number == number.rounded() ? String(Int(number)) : String(number)
        case let .bool(flag): return flag ? "true" : "false"
        case .list, .null, .object: return nil
        }
    }

    /// A list as the server reads one: an array, or one string with an entry per line.
    public var lines: [String] {
        switch self {
        case let .list(items): return items.compactMap(\.text).flatMap { $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
        case let .string(text): return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: return []
        }
    }

    /// A flag as Rails casts one: true, "1", "true".
    public var flag: Bool {
        switch self {
        case let .bool(flag): return flag
        case let .string(text): return ["1", "true", "t", "yes", "on"].contains(text.lowercased())
        case let .number(number): return number != 0
        default: return false
        }
    }
}

/// The time zones the web form offers, by the names Rails stores (`ActiveSupport::TimeZone`):
/// the US zones first, then the rest, as its select lists them. The form writes these names
/// rather than IANA identifiers so the web's select still finds what the phone chose.
public struct ScheduleTimeZone: Hashable, Sendable, Identifiable {
    public var name: String
    public var identifier: String
    public var id: String { name }

    /// The option as the web's select prints it: the offset in force, then the name.
    public func label(at date: Date = Date()) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return name }
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600
        let minutes = (abs(seconds) % 3600) / 60
        return String(format: "(GMT%@%02d:%02d) %@", sign, hours, minutes, name)
    }

    public static let us: [ScheduleTimeZone] = [
        ("America/Adak", "America/Adak"), ("Hawaii", "Pacific/Honolulu"), ("Alaska", "America/Juneau"), ("America/Anchorage", "America/Anchorage"),
        ("America/Metlakatla", "America/Metlakatla"), ("America/Nome", "America/Nome"), ("America/Sitka", "America/Sitka"), ("America/Yakutat", "America/Yakutat"),
        ("Pacific Time (US & Canada)", "America/Los_Angeles"), ("America/Boise", "America/Boise"), ("Arizona", "America/Phoenix"),
        ("Mountain Time (US & Canada)", "America/Denver"), ("America/Indiana/Knox", "America/Indiana/Knox"), ("America/Indiana/Tell_City", "America/Indiana/Tell_City"),
        ("America/Menominee", "America/Menominee"), ("America/North_Dakota/Beulah", "America/North_Dakota/Beulah"), ("America/North_Dakota/Center", "America/North_Dakota/Center"),
        ("America/North_Dakota/New_Salem", "America/North_Dakota/New_Salem"), ("Central Time (US & Canada)", "America/Chicago"), ("America/Detroit", "America/Detroit"),
        ("America/Indiana/Marengo", "America/Indiana/Marengo"), ("America/Indiana/Petersburg", "America/Indiana/Petersburg"), ("America/Indiana/Vevay", "America/Indiana/Vevay"),
        ("America/Indiana/Vincennes", "America/Indiana/Vincennes"), ("America/Indiana/Winamac", "America/Indiana/Winamac"), ("America/Kentucky/Louisville", "America/Kentucky/Louisville"),
        ("America/Kentucky/Monticello", "America/Kentucky/Monticello"), ("Eastern Time (US & Canada)", "America/New_York"), ("Indiana (East)", "America/Indiana/Indianapolis"),
    ].map { ScheduleTimeZone(name: $0.0, identifier: $0.1) }

    public static let rest: [ScheduleTimeZone] = [
        ("International Date Line West", "Etc/GMT+12"), ("American Samoa", "Pacific/Pago_Pago"), ("Midway Island", "Pacific/Midway"), ("Tijuana", "America/Tijuana"),
        ("Mazatlan", "America/Mazatlan"), ("Central America", "America/Guatemala"), ("Chihuahua", "America/Chihuahua"), ("Guadalajara", "America/Mexico_City"),
        ("Mexico City", "America/Mexico_City"), ("Monterrey", "America/Monterrey"), ("Saskatchewan", "America/Regina"), ("Bogota", "America/Bogota"),
        ("Lima", "America/Lima"), ("Quito", "America/Lima"), ("Atlantic Time (Canada)", "America/Halifax"), ("Caracas", "America/Caracas"),
        ("Georgetown", "America/Guyana"), ("La Paz", "America/La_Paz"), ("Puerto Rico", "America/Puerto_Rico"), ("Santiago", "America/Santiago"),
        ("Newfoundland", "America/St_Johns"), ("Asuncion", "America/Asuncion"), ("Brasilia", "America/Sao_Paulo"), ("Buenos Aires", "America/Argentina/Buenos_Aires"),
        ("Montevideo", "America/Montevideo"), ("Greenland", "America/Nuuk"), ("Mid-Atlantic", "Atlantic/South_Georgia"), ("Azores", "Atlantic/Azores"),
        ("Cape Verde Is.", "Atlantic/Cape_Verde"), ("Edinburgh", "Europe/London"), ("Lisbon", "Europe/Lisbon"), ("London", "Europe/London"),
        ("Monrovia", "Africa/Monrovia"), ("UTC", "Etc/UTC"), ("Amsterdam", "Europe/Amsterdam"), ("Belgrade", "Europe/Belgrade"),
        ("Berlin", "Europe/Berlin"), ("Bern", "Europe/Zurich"), ("Bratislava", "Europe/Bratislava"), ("Brussels", "Europe/Brussels"),
        ("Budapest", "Europe/Budapest"), ("Casablanca", "Africa/Casablanca"), ("Copenhagen", "Europe/Copenhagen"), ("Dublin", "Europe/Dublin"),
        ("Ljubljana", "Europe/Ljubljana"), ("Madrid", "Europe/Madrid"), ("Paris", "Europe/Paris"), ("Prague", "Europe/Prague"),
        ("Rome", "Europe/Rome"), ("Sarajevo", "Europe/Sarajevo"), ("Skopje", "Europe/Skopje"), ("Stockholm", "Europe/Stockholm"),
        ("Vienna", "Europe/Vienna"), ("Warsaw", "Europe/Warsaw"), ("West Central Africa", "Africa/Algiers"), ("Zagreb", "Europe/Zagreb"),
        ("Zurich", "Europe/Zurich"), ("Athens", "Europe/Athens"), ("Bucharest", "Europe/Bucharest"), ("Cairo", "Africa/Cairo"),
        ("Harare", "Africa/Harare"), ("Helsinki", "Europe/Helsinki"), ("Jerusalem", "Asia/Jerusalem"), ("Kaliningrad", "Europe/Kaliningrad"),
        ("Pretoria", "Africa/Johannesburg"), ("Riga", "Europe/Riga"), ("Sofia", "Europe/Sofia"), ("Tallinn", "Europe/Tallinn"),
        ("Vilnius", "Europe/Vilnius"), ("Baghdad", "Asia/Baghdad"), ("Istanbul", "Europe/Istanbul"), ("Kuwait", "Asia/Kuwait"),
        ("Minsk", "Europe/Minsk"), ("Moscow", "Europe/Moscow"), ("Nairobi", "Africa/Nairobi"), ("Riyadh", "Asia/Riyadh"),
        ("St. Petersburg", "Europe/Moscow"), ("Volgograd", "Europe/Volgograd"), ("Tehran", "Asia/Tehran"), ("Abu Dhabi", "Asia/Muscat"),
        ("Baku", "Asia/Baku"), ("Muscat", "Asia/Muscat"), ("Samara", "Europe/Samara"), ("Tbilisi", "Asia/Tbilisi"),
        ("Yerevan", "Asia/Yerevan"), ("Kabul", "Asia/Kabul"), ("Almaty", "Asia/Almaty"), ("Astana", "Asia/Almaty"),
        ("Ekaterinburg", "Asia/Yekaterinburg"), ("Islamabad", "Asia/Karachi"), ("Karachi", "Asia/Karachi"), ("Tashkent", "Asia/Tashkent"),
        ("Chennai", "Asia/Kolkata"), ("Kolkata", "Asia/Kolkata"), ("Mumbai", "Asia/Kolkata"), ("New Delhi", "Asia/Kolkata"),
        ("Sri Jayawardenepura", "Asia/Colombo"), ("Kathmandu", "Asia/Kathmandu"), ("Dhaka", "Asia/Dhaka"), ("Urumqi", "Asia/Urumqi"),
        ("Bangkok", "Asia/Bangkok"), ("Hanoi", "Asia/Bangkok"), ("Jakarta", "Asia/Jakarta"), ("Krasnoyarsk", "Asia/Krasnoyarsk"),
        ("Novosibirsk", "Asia/Novosibirsk"), ("Beijing", "Asia/Shanghai"), ("Chongqing", "Asia/Chongqing"), ("Hong Kong", "Asia/Hong_Kong"),
        ("Irkutsk", "Asia/Irkutsk"), ("Kuala Lumpur", "Asia/Kuala_Lumpur"), ("Perth", "Australia/Perth"), ("Singapore", "Asia/Singapore"),
        ("Taipei", "Asia/Taipei"), ("Ulaanbaatar", "Asia/Ulaanbaatar"), ("Osaka", "Asia/Tokyo"), ("Sapporo", "Asia/Tokyo"),
        ("Seoul", "Asia/Seoul"), ("Tokyo", "Asia/Tokyo"), ("Yakutsk", "Asia/Yakutsk"), ("Adelaide", "Australia/Adelaide"),
        ("Darwin", "Australia/Darwin"), ("Brisbane", "Australia/Brisbane"), ("Canberra", "Australia/Canberra"), ("Guam", "Pacific/Guam"),
        ("Hobart", "Australia/Hobart"), ("Melbourne", "Australia/Melbourne"), ("Port Moresby", "Pacific/Port_Moresby"), ("Sydney", "Australia/Sydney"),
        ("Vladivostok", "Asia/Vladivostok"), ("Magadan", "Asia/Magadan"), ("New Caledonia", "Pacific/Noumea"), ("Solomon Is.", "Pacific/Guadalcanal"),
        ("Srednekolymsk", "Asia/Srednekolymsk"), ("Auckland", "Pacific/Auckland"), ("Fiji", "Pacific/Fiji"), ("Kamchatka", "Asia/Kamchatka"),
        ("Marshall Is.", "Pacific/Majuro"), ("Wellington", "Pacific/Auckland"), ("Chatham Is.", "Pacific/Chatham"), ("Nuku'alofa", "Pacific/Tongatapu"),
        ("Samoa", "Pacific/Apia"), ("Tokelau Is.", "Pacific/Fakaofo"),
    ].map { ScheduleTimeZone(name: $0.0, identifier: $0.1) }

    /// The picker's list for a stored value: UTC and the US zones first (as the web's select for
    /// a new condition and for a saved one, respectively), then the rest, and a stored name none
    /// of them carry kept as its own entry so an edit does not silently move the schedule.
    public static func options(including stored: String) -> [ScheduleTimeZone] {
        var list = [ScheduleTimeZone(name: "UTC", identifier: "Etc/UTC")] + us + rest.filter { $0.name != "UTC" }
        if !stored.isEmpty, !list.contains(where: { $0.name == stored }) {
            list.insert(ScheduleTimeZone(name: stored, identifier: TimeZone(identifier: stored)?.identifier ?? stored), at: 0)
        }
        return list
    }
}

/// A Slack channel the bot can see (`GET /api/v1/triggers/channels`).
public struct SlackChannel: Hashable, Sendable, Decodable, Identifiable {
    public var id: String
    public var name: String
    public var isPrivate: Bool
    public var memberCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case isPrivate = "is_private"
        case memberCount = "num_members"
    }

    public init(id: String, name: String, isPrivate: Bool = false, memberCount: Int? = nil) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
        self.memberCount = memberCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? id
        isPrivate = ((try? container.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? nil) ?? false
        memberCount = try? container.decodeIfPresent(Int.self, forKey: .memberCount)
    }

    /// As the web's option prints it: a lock for a private channel, a hash for the rest.
    public var label: String { isPrivate ? "🔒 \(name)" : "#\(name)" }
}

/// A WhatsApp chat the bridge's account is in (`GET /api/v1/triggers/whatsapp_chats`).
public struct WhatsAppChat: Hashable, Sendable, Decodable, Identifiable {
    public var id: String
    public var name: String
    public var isGroup: Bool
    public var lastMessageAt: Date?
    public var participantCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case isGroup = "is_group"
        case lastMessageAt = "last_message_at"
        case participantCount = "participant_count"
    }

    public init(id: String, name: String, isGroup: Bool = false, lastMessageAt: Date? = nil, participantCount: Int? = nil) {
        self.id = id
        self.name = name
        self.isGroup = isGroup
        self.lastMessageAt = lastMessageAt
        self.participantCount = participantCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? id
        isGroup = ((try? container.decodeIfPresent(Bool.self, forKey: .isGroup)) ?? nil) ?? false
        lastMessageAt = try? container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        participantCount = try? container.decodeIfPresent(Int.self, forKey: .participantCount)
    }

    /// As the web's option prints it.
    public var label: String { isGroup ? "\(name) (group)" : name }
}

/// What a trigger write came back with: the trigger, and what the web page would flash.
public struct TriggerWrite: Hashable, Sendable {
    public var trigger: TriggerSummary
    /// Conditions the write was allowed to store and still has to be known about: the agent
    /// root is not in the catalog, say. The trigger exists and is enabled.
    public var warnings: [String]
    /// How many of the trigger's waiting sessions an update moved between scheduling classes;
    /// nil when the class was not touched.
    public var reclassifiedWaitingSessions: Int?

    public init(trigger: TriggerSummary, warnings: [String] = [], reclassifiedWaitingSessions: Int? = nil) {
        self.trigger = trigger
        self.warnings = warnings
        self.reclassifiedWaitingSessions = reclassifiedWaitingSessions
    }

    /// The web page's flash after a save, or nil when it would say nothing beyond "saved".
    public var notice: String? {
        var lines = warnings
        if let moved = reclassifiedWaitingSessions, moved > 0 {
            lines.append("\(moved) waiting session\(moved == 1 ? "" : "s") moved to the new scheduling class.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

/// The server refused the write (422): nothing was saved, and these are its reasons, in the
/// words the web form lists under "prohibited this trigger from being saved".
public struct TriggerValidationError: Error, Hashable, Sendable {
    public var messages: [String]

    public init(messages: [String]) {
        self.messages = messages
    }

    /// The web form's heading over the list.
    public var headline: String {
        "\(messages.count) error\(messages.count == 1 ? "" : "s") prohibited this trigger from being saved:"
    }
}

struct TriggerWriteResponse: Decodable {
    let trigger: TriggerSummary
    let warnings: [String]?
    let reclassified_waiting_sessions: Int?
}

struct SlackChannelsResponse: Decodable {
    let channels: [SlackChannel]
}

struct WhatsAppChatsResponse: Decodable {
    let chats: [WhatsAppChat]
}
