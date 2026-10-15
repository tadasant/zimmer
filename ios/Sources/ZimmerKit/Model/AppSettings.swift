import Foundation

/// The Settings page's row, as `GET /api/v1/app_settings` describes it: the global session
/// defaults, every Settings → Experimental toggle, and the MCP Apps switch with its
/// per-server allowlist. A `PATCH` answers with the same shape, after the save.
public struct AppSettings: Codable, Hashable, Sendable {
    /// The effective runtime and model pair, whether each half is an operator override, and
    /// the shipped pair an empty override falls back to.
    public struct SessionDefaults: Codable, Hashable, Sendable {
        public struct Pair: Codable, Hashable, Sendable {
            public var runtime: String
            public var model: String

            public init(runtime: String, model: String) {
                self.runtime = runtime
                self.model = model
            }
        }

        public var runtime: String
        public var model: String
        public var runtimeOverridden: Bool
        public var modelOverridden: Bool
        public var builtIn: Pair

        enum CodingKeys: String, CodingKey {
            case runtime, model
            case runtimeOverridden = "runtime_overridden"
            case modelOverridden = "model_overridden"
            case builtIn = "built_in"
        }

        public init(runtime: String, model: String, runtimeOverridden: Bool, modelOverridden: Bool, builtIn: Pair) {
            self.runtime = runtime
            self.model = model
            self.runtimeOverridden = runtimeOverridden
            self.modelOverridden = modelOverridden
            self.builtIn = builtIn
        }

        /// The page's "Active global default" case: either half set by an operator.
        public var isOverridden: Bool { runtimeOverridden || modelOverridden }
    }

    /// One registered runtime: its label, its default model and the models it offers.
    public struct Runtime: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var defaultModel: String
        public var models: [String]

        enum CodingKeys: String, CodingKey {
            case id, label, models
            case defaultModel = "default_model"
        }

        public init(id: String, label: String, defaultModel: String, models: [String]) {
            self.id = id
            self.label = label
            self.defaultModel = defaultModel
            self.models = models
        }
    }

    /// One Settings → Experimental toggle, in the page's order.
    public struct Experimental: Codable, Hashable, Sendable, Identifiable {
        public var key: String
        public var title: String
        public var description: String
        public var enabled: Bool
        public var defaultEnabled: Bool
        /// Backed by a Zimmer Extension rather than an `AppSetting` column.
        public var isExtension: Bool

        public var id: String { key }

        enum CodingKeys: String, CodingKey {
            case key, title, description, enabled
            case defaultEnabled = "default_enabled"
            case isExtension = "extension"
        }

        public init(key: String, title: String, description: String, enabled: Bool, defaultEnabled: Bool, isExtension: Bool = false) {
            self.key = key
            self.title = title
            self.description = description
            self.enabled = enabled
            self.defaultEnabled = defaultEnabled
            self.isExtension = isExtension
        }

        /// The page's status banner for a toggle in state `on`: "<title> is ON (recommended
        /// default)." when that is the shipped state, "<title> is OFF." when it is not.
        public func statusLine(on: Bool) -> String {
            "\(title) is \(on ? "ON" : "OFF")\(on == defaultEnabled ? " (recommended default)" : "")."
        }

        public var statusLine: String { statusLine(on: enabled) }
    }

    /// The MCP Apps master switch and allowlist. The allowlist can only name an eligible
    /// server; a remote MCP server from the catalog.
    public struct McpApps: Codable, Hashable, Sendable {
        public struct Server: Codable, Hashable, Sendable, Identifiable {
            public var name: String
            public var title: String

            public var id: String { name }

            public init(name: String, title: String) {
                self.name = name
                self.title = title
            }
        }

        public var enabled: Bool
        public var allowedServers: [String]
        public var eligibleServers: [Server]

        enum CodingKeys: String, CodingKey {
            case enabled
            case allowedServers = "allowed_servers"
            case eligibleServers = "eligible_servers"
        }

        public init(enabled: Bool, allowedServers: [String], eligibleServers: [Server]) {
            self.enabled = enabled
            self.allowedServers = allowedServers
            self.eligibleServers = eligibleServers
        }
    }

    public var sessionDefaults: SessionDefaults
    public var runtimes: [Runtime]
    public var experimental: [Experimental]
    public var mcpApps: McpApps

    enum CodingKeys: String, CodingKey {
        case runtimes, experimental
        case sessionDefaults = "session_defaults"
        case mcpApps = "mcp_apps"
    }

    public init(sessionDefaults: SessionDefaults, runtimes: [Runtime], experimental: [Experimental], mcpApps: McpApps) {
        self.sessionDefaults = sessionDefaults
        self.runtimes = runtimes
        self.experimental = experimental
        self.mcpApps = mcpApps
    }

    public func runtime(_ id: String) -> Runtime? { runtimes.first { $0.id == id } }

    /// The runtime's label, or its id where the server lists no such runtime.
    public func runtimeLabel(_ id: String) -> String { runtime(id)?.label ?? id }

    /// The models `runtime` offers, or none when the server lists no such runtime.
    public func models(for runtime: String) -> [String] { self.runtime(runtime)?.models ?? [] }

    /// The page's banner over the Session Defaults form.
    public var sessionDefaultsBanner: String {
        let defaults = sessionDefaults
        if defaults.isOverridden {
            return "Active global default: \(runtimeLabel(defaults.runtime)) / \(defaults.model)"
        }
        return "No global override set — using the built-in default (\(runtimeLabel(defaults.builtIn.runtime)) / \(defaults.builtIn.model))."
    }
}

/// The body of `PATCH /api/v1/app_settings`: any subset of the row, and only the keys sent
/// are touched. An empty `defaultRuntime` or `defaultModel` clears that override.
public struct AppSettingsChange: Hashable, Sendable {
    public var defaultRuntime: String?
    public var defaultModel: String?
    public var experimental: [String: Bool]
    public var mcpAppsEnabled: Bool?
    public var mcpAppsAllowedServers: [String]?

    public init(defaultRuntime: String? = nil, defaultModel: String? = nil, experimental: [String: Bool] = [:],
                mcpAppsEnabled: Bool? = nil, mcpAppsAllowedServers: [String]? = nil) {
        self.defaultRuntime = defaultRuntime
        self.defaultModel = defaultModel
        self.experimental = experimental
        self.mcpAppsEnabled = mcpAppsEnabled
        self.mcpAppsAllowedServers = mcpAppsAllowedServers
    }

    /// The MCP Apps keys are a person's to change: the server refuses them on a grant that
    /// does not act as you, before reading anything else.
    public var touchesMcpApps: Bool { mcpAppsEnabled != nil || mcpAppsAllowedServers != nil }

    public var body: [String: Any] {
        var settings: [String: Any] = [:]
        if let defaultRuntime { settings["default_runtime"] = defaultRuntime }
        if let defaultModel { settings["default_model"] = defaultModel }
        if !experimental.isEmpty { settings["experimental"] = experimental }
        if let mcpAppsEnabled { settings["mcp_apps_enabled"] = mcpAppsEnabled }
        if let mcpAppsAllowedServers { settings["mcp_apps_allowed_servers"] = mcpAppsAllowedServers }
        return ["app_settings": settings]
    }
}
