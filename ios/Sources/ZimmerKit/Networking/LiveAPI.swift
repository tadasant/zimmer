import Foundation

/// Live Mode over `/api/v1/live*` — the same rules the web's `/live` pages keep
/// (`LiveConversations::Actions` on the server).
public protocol LiveAPI: Sendable {
    /// Can Live Mode start, and if not, why not.
    func liveAvailability() async throws -> LiveAvailability
    /// The newest conversations and the open one.
    func liveConversations() async throws -> LiveOverview
    /// One conversation with its turns; `afterTurn` reads only turns newer than that one.
    func liveConversation(_ id: Int, afterTurn: Int?) async throws -> LiveConversation
    /// Start a fresh conversation, typed or spoken from the start, ending the open one.
    func startLiveConversation(_ mode: LiveMode) async throws -> LiveConversation
    func finishLiveConversation(_ id: Int) async throws -> LiveConversation
    /// Typed ⇄ spoken, in the same conversation. Voice must be on before a call can mint its
    /// secret; typing waits for it to be off.
    func setLiveMode(_ id: Int, mode: LiveMode) async throws -> LiveConversation
    /// Typed: a message. The reply arrives as a later turn.
    func sendLiveMessage(_ id: Int, content: String) async throws -> LiveTurn
    /// Voice: the short-lived secret to open the Realtime connection with.
    func liveClientSecret(_ id: Int) async throws -> LiveClientSecret
    /// Voice: run a function call the model made; send back what this returns.
    func relayLiveToolCall(_ id: Int, name: String, arguments: String, callID: String) async throws -> LiveToolResult
    /// Voice: a finished transcript line, so the thread carries what was said.
    func recordLiveTurn(_ id: Int, role: LiveTurn.Role, content: String) async throws -> LiveTurn
    /// Voice: the `session` of a `session.update` that brings an open call up to the current
    /// Live settings and guidance — sent after they changed somewhere else, such as the settings
    /// screen.
    func liveSessionUpdate(_ id: Int) async throws -> JSONValue

    /// The Live settings, each field's choices or range, the guidance, and recent history.
    func liveSettings() async throws -> LiveSettings
    /// Change some: setting keys (a string or a number; `""` or `"default"` puts one back),
    /// `guidance` to replace it, `append_guidance` to add a line. 422 on an unknown key or a
    /// value not among a field's options; a number out of range is clamped and `summary` says so.
    func updateLiveSettings(_ changes: [String: JSONValue]) async throws -> LiveSettings
    /// Every setting back to its default. The guidance is kept.
    func resetLiveSettings() async throws -> LiveSettings
    /// The guidance as it was before change `changeID`. 422 when that change did not touch it.
    func restoreLiveGuidance(changeID: Int) async throws -> LiveSettings
}

struct LiveSessionUpdateResponse: Decodable {
    let session: JSONValue
}

/// `current_id` is the open conversation; a server from before voice folded into Live Mode sends
/// only `current`, keyed by mode.
struct LiveIndexResponse: Decodable {
    let live_conversations: [LiveConversation]
    let current_id: Int?
    let current: [String: Int?]?

    var currentID: Int? { current_id ?? current?.values.compactMap { $0 }.max() }
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `LiveAPI`.
extension ZimmerHTTPClient {
    public func liveAvailability() async throws -> LiveAvailability {
        try await get("/api/v1/live")
    }

    public func liveConversations() async throws -> LiveOverview {
        let response: LiveIndexResponse = try await get("/api/v1/live_conversations")
        return LiveOverview(conversations: response.live_conversations, current: response.currentID)
    }

    public func liveConversation(_ id: Int, afterTurn: Int?) async throws -> LiveConversation {
        var query: [String: String] = [:]
        if let afterTurn { query["after_turn_id"] = String(afterTurn) }
        return try await get("/api/v1/live_conversations/\(id)", query: query)
    }

    public func startLiveConversation(_ mode: LiveMode) async throws -> LiveConversation {
        try await post("/api/v1/live_conversations", json: ["mode": mode.rawValue])
    }

    public func finishLiveConversation(_ id: Int) async throws -> LiveConversation {
        try await post("/api/v1/live_conversations/\(id)/finish", json: [:])
    }

    public func setLiveMode(_ id: Int, mode: LiveMode) async throws -> LiveConversation {
        try await post("/api/v1/live_conversations/\(id)/mode", json: ["mode": mode.rawValue])
    }

    public func sendLiveMessage(_ id: Int, content: String) async throws -> LiveTurn {
        try await post("/api/v1/live_conversations/\(id)/messages", json: ["content": content])
    }

    public func liveClientSecret(_ id: Int) async throws -> LiveClientSecret {
        try await post("/api/v1/live_conversations/\(id)/client_secret", json: [:])
    }

    public func relayLiveToolCall(_ id: Int, name: String, arguments: String, callID: String) async throws -> LiveToolResult {
        try await post("/api/v1/live_conversations/\(id)/tool_calls",
                       json: ["name": name, "arguments": arguments, "call_id": callID])
    }

    public func recordLiveTurn(_ id: Int, role: LiveTurn.Role, content: String) async throws -> LiveTurn {
        try await post("/api/v1/live_conversations/\(id)/turns", json: ["role": role.rawValue, "content": content])
    }

    public func liveSessionUpdate(_ id: Int) async throws -> JSONValue {
        let response: LiveSessionUpdateResponse = try await post("/api/v1/live_conversations/\(id)/session_update", json: [:])
        return response.session
    }

    public func liveSettings() async throws -> LiveSettings {
        try await get("/api/v1/live/settings")
    }

    public func updateLiveSettings(_ changes: [String: JSONValue]) async throws -> LiveSettings {
        try await patch("/api/v1/live/settings", json: changes.mapValues(\.foundationObject))
    }

    public func resetLiveSettings() async throws -> LiveSettings {
        try await post("/api/v1/live/settings/reset", json: [:])
    }

    public func restoreLiveGuidance(changeID: Int) async throws -> LiveSettings {
        try await post("/api/v1/live/settings/changes/\(changeID)/restore_guidance", json: [:])
    }
}
