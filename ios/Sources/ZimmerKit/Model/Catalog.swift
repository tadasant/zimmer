import Foundation

/// What a new session can be made of, as `GET /api/v1/configs` describes it — the lists the
/// web UI's new-session form offers.
public struct AppConfigs: Hashable, Sendable, Decodable {
    public var agentRoots: [AgentRootOption]
    /// Each runtime's models, keyed by runtime (`claude_code`, `codex`).
    public var runtimeModels: [String: RuntimeModels]
    public var goals: [GoalOption]
    public var mcpServers: [CatalogItem]

    enum CodingKeys: String, CodingKey {
        case goals
        case agentRoots = "agent_roots"
        case runtimeModels = "runtime_models"
        case mcpServers = "mcp_servers"
    }

    public init(agentRoots: [AgentRootOption], runtimeModels: [String: RuntimeModels], goals: [GoalOption] = [], mcpServers: [CatalogItem] = []) {
        self.agentRoots = agentRoots
        self.runtimeModels = runtimeModels
        self.goals = goals
        self.mcpServers = mcpServers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentRoots = (try? container.decodeIfPresent([AgentRootOption].self, forKey: .agentRoots)) ?? []
        runtimeModels = (try? container.decodeIfPresent([String: RuntimeModels].self, forKey: .runtimeModels)) ?? [:]
        goals = (try? container.decodeIfPresent([GoalOption].self, forKey: .goals)) ?? []
        mcpServers = (try? container.decodeIfPresent([CatalogItem].self, forKey: .mcpServers)) ?? []
    }

    /// The roots a person may start a session on — the form hides the rest.
    public var invocableRoots: [AgentRootOption] { agentRoots.filter { $0.userInvocable ?? true } }

    /// The models for `runtime`, or none when the server names no such runtime.
    public func models(for runtime: String) -> [ModelOption] { runtimeModels[runtime]?.models ?? [] }
}

public struct AgentRootOption: Hashable, Sendable, Decodable, Identifiable {
    public var name: String
    public var displayName: String?
    public var description: String?
    public var isDefault: Bool?
    public var userInvocable: Bool?
    public var defaultRuntime: String?
    public var defaultModel: String?
    public var defaultGoal: String?
    public var defaultMcpServers: [String]?
    public var defaultSkills: [String]?
    public var defaultHooks: [String]?
    public var defaultPlugins: [String]?

    public var id: String { name }
    public var title: String { displayName?.isEmpty == false ? displayName! : name }

    enum CodingKeys: String, CodingKey {
        case name, description
        case displayName = "display_name"
        case isDefault = "default"
        case userInvocable = "user_invocable"
        case defaultRuntime = "default_runtime"
        case defaultModel = "default_model"
        case defaultGoal = "default_goal"
        case defaultMcpServers = "default_mcp_servers"
        case defaultSkills = "default_skills"
        case defaultHooks = "default_hooks"
        case defaultPlugins = "default_plugins"
    }

    public init(name: String, displayName: String? = nil, description: String? = nil, isDefault: Bool? = nil,
                userInvocable: Bool? = true, defaultRuntime: String? = nil, defaultModel: String? = nil, defaultGoal: String? = nil,
                defaultMcpServers: [String]? = nil, defaultSkills: [String]? = nil, defaultHooks: [String]? = nil, defaultPlugins: [String]? = nil) {
        self.name = name
        self.displayName = displayName
        self.description = description
        self.isDefault = isDefault
        self.userInvocable = userInvocable
        self.defaultRuntime = defaultRuntime
        self.defaultModel = defaultModel
        self.defaultGoal = defaultGoal
        self.defaultMcpServers = defaultMcpServers
        self.defaultSkills = defaultSkills
        self.defaultHooks = defaultHooks
        self.defaultPlugins = defaultPlugins
    }
}

public struct RuntimeModels: Hashable, Sendable, Decodable {
    public var `default`: String?
    public var models: [ModelOption]

    public init(default defaultModel: String?, models: [ModelOption]) {
        self.default = defaultModel
        self.models = models
    }
}

public struct ModelOption: Hashable, Sendable, Decodable, Identifiable {
    public var id: String
    public var label: String?
    public var effortLevels: [String]
    public var defaultEffort: String?

    enum CodingKeys: String, CodingKey {
        case id, label
        case effortLevels = "effort_levels"
        case defaultEffort = "default_effort"
    }

    public init(id: String, label: String? = nil, effortLevels: [String] = [], defaultEffort: String? = nil) {
        self.id = id
        self.label = label
        self.effortLevels = effortLevels
        self.defaultEffort = defaultEffort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        effortLevels = (try? container.decodeIfPresent([String].self, forKey: .effortLevels)) ?? []
        defaultEffort = try? container.decodeIfPresent(String.self, forKey: .defaultEffort)
    }

    public var title: String { label?.isEmpty == false ? label! : id }
}

public struct GoalOption: Hashable, Sendable, Decodable, Identifiable {
    public var id: String
    public var name: String?
    public var description: String?

    public init(id: String, name: String? = nil, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// One entry of a catalog list — an MCP server, a skill, a hook or a plugin — reduced to what
/// a picker shows. Each list names its key differently (`name` for MCP servers, `id` for the
/// rest), and the value a session stores is that key.
public struct CatalogItem: Hashable, Sendable, Decodable, Identifiable {
    public var id: String
    public var title: String?
    public var description: String?
    /// An MCP server that cannot be used right now (it needs authorizing, say), and why.
    public var unavailableReason: String?

    enum CodingKeys: String, CodingKey {
        case id, name, title, description, unavailable
        case unavailableReason = "unavailable_reason"
    }

    public init(id: String, title: String? = nil, description: String? = nil, unavailableReason: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.unavailableReason = unavailableReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `id` where the list has one (skills, hooks, plugins); MCP servers are keyed by name.
        if let id = try? container.decode(String.self, forKey: .id) {
            self.id = id
        } else {
            id = try container.decode(String.self, forKey: .name)
        }
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        let unavailable = (try? container.decodeIfPresent(Bool.self, forKey: .unavailable)) ?? false
        unavailableReason = unavailable ? ((try? container.decodeIfPresent(String.self, forKey: .unavailableReason)) ?? "Unavailable") : nil
    }

    public var displayTitle: String { title?.isEmpty == false ? title! : id }
}

/// The four kinds of catalog artifact a session carries.
public enum CatalogKind: String, Hashable, Sendable, CaseIterable, Identifiable {
    case mcpServers, skills, hooks, plugins

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .mcpServers: return "MCP Servers"
        case .skills: return "Skills"
        case .hooks: return "Hooks"
        case .plugins: return "Plugins"
        }
    }

    /// The session field, the `PATCH /api/v1/sessions/:id/<path>` and the create parameter.
    var parameter: String {
        switch self {
        case .mcpServers: return "mcp_servers"
        case .skills: return "catalog_skills"
        case .hooks: return "catalog_hooks"
        case .plugins: return "catalog_plugins"
        }
    }

    /// What the session has chosen of this kind.
    public func selection(in session: SessionSummary) -> [String] {
        switch self {
        case .mcpServers: return session.mcpServers ?? []
        case .skills: return session.catalogSkills ?? []
        case .hooks: return session.catalogHooks ?? []
        case .plugins: return session.catalogPlugins ?? []
        }
    }

    /// What `root` starts a session with of this kind.
    public func defaults(of root: AgentRootOption) -> [String] {
        switch self {
        case .mcpServers: return root.defaultMcpServers ?? []
        case .skills: return root.defaultSkills ?? []
        case .hooks: return root.defaultHooks ?? []
        case .plugins: return root.defaultPlugins ?? []
        }
    }
}

/// The web UI's new-session form, as the app fills it in.
public struct NewSessionRequest: Hashable, Sendable {
    public var agentRoot: String
    public var prompt: String
    public var runtime: String?
    public var model: String?
    /// Nil for the model's default.
    public var effort: String?
    public var title: String?
    public var goal: String?
    /// `priority` or `spot`; nil derives it.
    public var schedulingClass: String?
    /// Each kind the person chose explicitly; a kind left out takes the root's defaults.
    public var selections: [CatalogKind: [String]]
    /// Names this create attempt, so a retry after a lost response returns the same session.
    public var idempotencyKey: String

    public init(agentRoot: String, prompt: String, runtime: String? = nil, model: String? = nil, effort: String? = nil,
                title: String? = nil, goal: String? = nil, schedulingClass: String? = nil,
                selections: [CatalogKind: [String]] = [:], idempotencyKey: String = UUID().uuidString) {
        self.agentRoot = agentRoot
        self.prompt = prompt
        self.runtime = runtime
        self.model = model
        self.effort = effort
        self.title = title
        self.goal = goal
        self.schedulingClass = schedulingClass
        self.selections = selections
        self.idempotencyKey = idempotencyKey
    }

    /// The body of `POST /api/v1/sessions`.
    public var body: [String: Any] {
        var json: [String: Any] = ["agent_root": agentRoot, "prompt": prompt, "idempotency_key": idempotencyKey]
        if let runtime { json["agent_runtime"] = runtime }
        var config: [String: String] = [:]
        if let model { config["model"] = model }
        if let effort { config["effort"] = effort }
        if !config.isEmpty { json["config"] = config }
        if let title, !title.isEmpty { json["title"] = title }
        if let goal, !goal.isEmpty { json["goal"] = goal }
        if let schedulingClass { json["scheduling_class"] = schedulingClass }
        for (kind, values) in selections { json[kind.parameter] = values }
        return json
    }
}
