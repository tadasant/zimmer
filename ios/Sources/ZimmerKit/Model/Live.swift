import Foundation

/// Live Mode: one continuous conversation with Zimmer, typed or spoken, run by a fast OpenAI
/// model that hands anything slow to a background session. The server's half is
/// `LiveConversation` and the `/api/v1/live*` routes (docs/sessions/live.md); this is what the
/// app reads of it.
///
/// Voice is not a separate mode with its own conversation: a conversation is in one of these at
/// a time and switches mid-thread (`LiveAPI.setLiveMode`).
public enum LiveMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Typed: answered through Chat Completions, on the server.
    case text
    /// Voice on: a Realtime call the phone holds.
    case voice

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .text: return "Typed"
        case .voice: return "Voice"
        }
    }
}

/// Whether Live Mode can start, and in words why not (no OpenAI key, or no agent root in the
/// catalog), with the model each mode answers on. `GET /api/v1/live`.
public struct LiveAvailability: Decodable, Sendable, Equatable {
    public let label: String
    public let agentRoot: String
    public let available: Bool
    public let reasons: [String]
    public let models: [LiveMode: String]

    public init(label: String = "Live Mode", agentRoot: String, available: Bool, reasons: [String] = [], models: [LiveMode: String] = [:]) {
        self.label = label
        self.agentRoot = agentRoot
        self.available = available
        self.reasons = reasons
        self.models = models
    }

    /// One entry of `modes`. A server from before voice folded into Live Mode sends only these,
    /// one per mode with its own root and availability; the typed one stands for the whole.
    private struct ModeEntry: Decodable {
        let mode: String
        let model: String?
        let agentRoot: String?
        let available: Bool?
        let reasons: [String]?

        enum CodingKeys: String, CodingKey {
            case mode, model, available, reasons
            case agentRoot = "agent_root"
        }
    }

    enum CodingKeys: String, CodingKey {
        case label, available, reasons, modes
        case agentRoot = "agent_root"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try c.decodeIfPresent([ModeEntry].self, forKey: .modes) ?? []
        let typed = entries.first { $0.mode == LiveMode.text.rawValue }
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "Live Mode"
        agentRoot = try c.decodeIfPresent(String.self, forKey: .agentRoot) ?? typed?.agentRoot ?? "live-mode"
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? typed?.available ?? false
        reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? typed?.reasons ?? []
        var models: [LiveMode: String] = [:]
        for entry in entries {
            if let mode = LiveMode(rawValue: entry.mode), let model = entry.model { models[mode] = model }
        }
        self.models = models
    }
}

public struct LiveConversation: Decodable, Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case preparing, active, ended, failed

        public var isOpen: Bool { self == .preparing || self == .active }
    }

    public let id: Int
    /// Typed or spoken, right now.
    public let mode: LiveMode
    public let status: Status
    public let title: String
    public let agentRoot: String
    public let model: String
    public let instructionsSource: String?
    public let mcpServers: [String]
    public let responding: Bool
    public let errorMessage: String?
    /// Present on `show`; for `after_turn_id` reads, only the turns after it.
    public let turns: [LiveTurn]?

    public init(id: Int, mode: LiveMode, status: Status, title: String, agentRoot: String, model: String,
                instructionsSource: String? = nil, mcpServers: [String] = [], responding: Bool = false,
                errorMessage: String? = nil, turns: [LiveTurn]? = nil) {
        self.id = id
        self.mode = mode
        self.status = status
        self.title = title
        self.agentRoot = agentRoot
        self.model = model
        self.instructionsSource = instructionsSource
        self.mcpServers = mcpServers
        self.responding = responding
        self.errorMessage = errorMessage
        self.turns = turns
    }

    enum CodingKeys: String, CodingKey {
        case id, mode, status, title, model, responding, turns
        case agentRoot = "agent_root"
        case instructionsSource = "instructions_source"
        case mcpServers = "mcp_servers"
        case errorMessage = "error_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        mode = try c.decode(LiveMode.self, forKey: .mode)
        // A status this version does not know reads as ended: the conversation cannot be used.
        status = Status(rawValue: try c.decode(String.self, forKey: .status)) ?? .ended
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Live Mode"
        agentRoot = try c.decodeIfPresent(String.self, forKey: .agentRoot) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        instructionsSource = try c.decodeIfPresent(String.self, forKey: .instructionsSource)
        mcpServers = try c.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
        responding = try c.decodeIfPresent(Bool.self, forKey: .responding) ?? false
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        turns = try c.decodeIfPresent([LiveTurn].self, forKey: .turns)
    }
}

/// One entry in the thread: something said or typed, an answer, or a tool call and its output.
public struct LiveTurn: Decodable, Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable, Equatable {
        case user, assistant, tool
    }

    public let id: Int
    public let role: Role
    /// `typed` or `spoken`.
    public let source: String?
    public let content: String?
    public let toolName: String?
    /// For a `zimmer` gateway call, the Zimmer tool it called.
    public let zimmerTool: String?
    public let toolOutput: String?
    public let toolError: Bool

    public init(id: Int, role: Role, source: String? = nil, content: String? = nil, toolName: String? = nil,
                zimmerTool: String? = nil, toolOutput: String? = nil, toolError: Bool = false) {
        self.id = id
        self.role = role
        self.source = source
        self.content = content
        self.toolName = toolName
        self.zimmerTool = zimmerTool
        self.toolOutput = toolOutput
        self.toolError = toolError
    }

    /// "zimmer → quick_router" for a gateway call, the function name otherwise — what the web
    /// thread shows on a tool turn.
    public var toolLabel: String {
        if toolName == "zimmer", let zimmerTool, !zimmerTool.isEmpty { return "zimmer → \(zimmerTool)" }
        return toolName ?? "tool"
    }

    enum CodingKeys: String, CodingKey {
        case id, role, source, content
        case toolName = "tool_name"
        case toolArguments = "tool_arguments"
        case toolOutput = "tool_output"
        case toolError = "tool_error"
    }

    private struct GatewayArguments: Decodable {
        let tool: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        role = Role(rawValue: try c.decode(String.self, forKey: .role)) ?? .assistant
        source = try c.decodeIfPresent(String.self, forKey: .source)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        zimmerTool = (try? c.decodeIfPresent(GatewayArguments.self, forKey: .toolArguments))?.tool
        toolOutput = try c.decodeIfPresent(String.self, forKey: .toolOutput)
        toolError = try c.decodeIfPresent(Bool.self, forKey: .toolError) ?? false
    }
}

/// `GET /api/v1/live_conversations`: the recent conversations and the open one.
public struct LiveOverview: Sendable, Equatable {
    public let conversations: [LiveConversation]
    /// The one open conversation, typed or spoken.
    public let current: Int?

    public init(conversations: [LiveConversation], current: Int?) {
        self.conversations = conversations
        self.current = current
    }
}

/// What a voice call opens its audio connection with: a short-lived OpenAI Realtime secret whose
/// session config Zimmer chose. `POST /api/v1/live_conversations/:id/client_secret`.
public struct LiveClientSecret: Decodable, Sendable, Equatable {
    public let clientSecret: String
    public let model: String
    /// `wss://…/v1/realtime?model=…` — what the phone connects to, with the secret as bearer.
    public let websocketURL: URL
    /// Which lines the call answers: `always`, `wake_word` or `dynamic`. Absent from a server
    /// from before Listening, whose calls answer everything.
    public let listening: String?
    /// How much the app reports about the call (`LiveTelemetryLevel`, or `off`): the Live setting
    /// `voice_telemetry`. Absent from a server from before it.
    public let telemetry: String?

    public init(clientSecret: String, model: String, websocketURL: URL, listening: String? = nil, telemetry: String? = nil) {
        self.clientSecret = clientSecret
        self.model = model
        self.websocketURL = websocketURL
        self.listening = listening
        self.telemetry = telemetry
    }

    enum CodingKeys: String, CodingKey {
        case model, listening, telemetry
        case clientSecret = "client_secret"
        case websocketURL = "websocket_url"
    }
}

/// What Zimmer answered for a recorded transcript line: whether the call should answer it, and
/// whether it was dropped instead of written to the thread.
public struct LiveHeard: Decodable, Sendable, Equatable {
    public let respond: Bool
    public let dropped: Bool

    public init(respond: Bool, dropped: Bool = false) {
        self.respond = respond
        self.dropped = dropped
    }

    enum CodingKeys: String, CodingKey { case respond, dropped }

    /// A server from before Listening answers with the turn alone: kept, and answered.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        respond = try container.decodeIfPresent(Bool.self, forKey: .respond) ?? true
        dropped = try container.decodeIfPresent(Bool.self, forKey: .dropped) ?? false
    }
}

/// What Zimmer answered for one relayed function call.
public struct LiveToolResult: Decodable, Sendable, Equatable {
    /// What to send back as the `function_call_output`.
    public let output: String
    public let error: Bool
    /// The call enabled or disabled a server: send `tools` in a `session.update`.
    public let toolsChanged: Bool
    public let tools: JSONValue?
    /// The call changed a Live setting an open call can take: send this as the `session.update`
    /// instead of the tools-only one. It carries the tools too.
    public let session: JSONValue?

    public init(output: String, error: Bool = false, toolsChanged: Bool = false, tools: JSONValue? = nil, session: JSONValue? = nil) {
        self.output = output
        self.error = error
        self.toolsChanged = toolsChanged
        self.tools = tools
        self.session = session
    }

    enum CodingKeys: String, CodingKey {
        case output, error, tools, session
        case toolsChanged = "tools_changed"
    }
}

/// Any JSON value — for the parts of the Realtime protocol (events, tool schemas) the app relays
/// without modelling.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(value): try c.encode(value)
        case let .number(value): try c.encode(value)
        case let .string(value): try c.encode(value)
        case let .array(value): try c.encode(value)
        case let .object(value): try c.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// Compact JSON text, keys sorted.
    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    public static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
