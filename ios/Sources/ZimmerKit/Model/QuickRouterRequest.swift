import Foundation

/// A Quick Router start: the words, and what the web bubble's Advanced accordion and
/// attach buttons add. Blank options are not sent, so the server resolves them the way it
/// does for an untouched panel — the router root's harness, the ordinary model chain, and a
/// priority start, which is what the server gives a native start that names no class.
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
    /// The screen the router was opened on, as the web bubble sends the page it was typed on.
    public var page: QuickRouterPage?

    public init(prompt: String, runtime: String? = nil, model: String? = nil, spot: Bool = false,
                parentSessionID: Int? = nil, attachments: [MessageAttachment] = [], page: QuickRouterPage? = nil) {
        self.prompt = prompt
        self.runtime = runtime
        self.model = model
        self.spot = spot
        self.parentSessionID = parentSessionID
        self.attachments = attachments
        self.page = page
    }

    /// The body `POST /api/v1/quick_router` reads. Only what was chosen is sent.
    var json: [String: Any] {
        var json: [String: Any] = ["prompt": prompt]
        if let runtime, !runtime.isEmpty { json["agent_runtime"] = runtime }
        if let model, !model.isEmpty { json["model"] = model }
        if spot { json["scheduling_class"] = "spot" }
        if let parentSessionID { json["parent_session_id"] = parentSessionID }
        if !attachments.isEmpty { json["attachments"] = attachments.map(\.json) }
        if let page {
            if let url = page.url { json["page_url"] = url.absoluteString }
            json["page_title"] = page.title
            if let context = page.context, !context.isEmpty { json["page_context"] = context }
        }
        return json
    }
}

/// What the web bubble calls page context: the page the words were typed on (`page_url`,
/// `page_title`), and what it showed (`page_context`). The server wraps the three into the
/// prompt only when there is context; the URL and title alone go to the session's metadata.
public struct QuickRouterPage: Hashable, Sendable {
    public var url: URL?
    public var title: String
    public var context: String?

    public init(url: URL?, title: String, context: String? = nil) {
        self.url = url
        self.title = title
        self.context = context
    }

    /// A session's page: its web URL and title, and the header's facts as the context — what
    /// the bubble's page capture would read off the same page.
    public static func session(_ session: SessionSummary, url: URL?) -> QuickRouterPage {
        var facts = ["Zimmer session #\(session.id): \(session.displayTitle)", "Status: \(session.status.label)"]
        if let root = session.agentRoot { facts.append("Agent root: \(root)") }
        if let klass = session.priorityClass { facts.append("Scheduling class: \(klass)") }
        if let goal = session.goal, !goal.isEmpty { facts.append("Goal: \(goal)") }
        return QuickRouterPage(url: url, title: session.displayTitle, context: facts.joined(separator: "\n"))
    }
}

extension ZimmerAPI {
    /// A start from the words alone.
    public func startQuickRouter(_ prompt: String) async throws -> Int {
        try await startQuickRouter(QuickRouterRequest(prompt: prompt))
    }
}
