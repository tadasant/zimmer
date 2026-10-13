import Foundation

/// A Quick Router start: the words, and what the web bubble's Advanced accordion and
/// attach buttons add. Blank options are not sent, so the server resolves them the way it
/// does for an untouched panel — the router root's harness, the ordinary model chain, a
/// priority start.
public struct QuickRouterRequest: Hashable, Sendable {
    public var prompt: String
    /// A registered harness, or nil for the router root's own.
    public var runtime: String?
    /// A model the harness offers, or nil for the ordinary chain.
    public var model: String?
    /// Wait for quota room instead of starting now; lands at the top of the spot queue.
    public var spot: Bool
    /// The session this was asked from, so the new one threads under it.
    public var parentSessionID: Int?
    public var attachments: [MessageAttachment]

    public init(prompt: String, runtime: String? = nil, model: String? = nil, spot: Bool = false,
                parentSessionID: Int? = nil, attachments: [MessageAttachment] = []) {
        self.prompt = prompt
        self.runtime = runtime
        self.model = model
        self.spot = spot
        self.parentSessionID = parentSessionID
        self.attachments = attachments
    }

    /// The body `POST /api/v1/quick_router` reads. Only what was chosen is sent.
    var json: [String: Any] {
        var json: [String: Any] = ["prompt": prompt]
        if let runtime, !runtime.isEmpty { json["agent_runtime"] = runtime }
        if let model, !model.isEmpty { json["model"] = model }
        if spot { json["scheduling_class"] = "spot" }
        if let parentSessionID { json["parent_session_id"] = parentSessionID }
        if !attachments.isEmpty { json["attachments"] = attachments.map(\.json) }
        return json
    }
}

extension ZimmerAPI {
    /// A start from the words alone.
    public func startQuickRouter(_ prompt: String) async throws -> Int {
        try await startQuickRouter(QuickRouterRequest(prompt: prompt))
    }
}
