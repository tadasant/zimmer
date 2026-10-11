import Foundation

/// The web UI's new-session form and the session settings it edits afterwards: the model,
/// and the MCP servers, skills, hooks and plugins a session carries. The catalogs are
/// read-only to the app's token (`accepts_native_app_tokens only: %i[index]`); creating a
/// session and changing one are on `SessionsController`, which the token already reached.
public protocol CatalogAPI: Sendable {
    /// Agent roots, models, goals and MCP servers (`GET /api/v1/configs`).
    func configs() async throws -> AppConfigs
    /// One catalog's entries.
    func catalog(_ kind: CatalogKind) async throws -> [CatalogItem]
    /// Start a session; it begins its first turn if `prompt` is not empty.
    func createSession(_ request: NewSessionRequest) async throws -> SessionSummary
    /// Switch the session's model, for its next turn.
    func updateModel(_ id: Int, model: String) async throws -> SessionSummary
    /// Replace one kind of artifact on the session. Takes effect on its next prepare.
    func updateSelection(_ id: Int, _ kind: CatalogKind, to values: [String]) async throws -> SessionSummary
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `CatalogAPI`.
extension ZimmerHTTPClient {
    public func configs() async throws -> AppConfigs {
        try await get("/api/v1/configs")
    }

    public func catalog(_ kind: CatalogKind) async throws -> [CatalogItem] {
        switch kind {
        case .mcpServers:
            let response: CatalogList = try await get("/api/v1/mcp_servers")
            return response.mcp_servers ?? []
        case .skills:
            let response: CatalogList = try await get("/api/v1/skills")
            return response.skills ?? []
        case .hooks:
            let response: CatalogList = try await get("/api/v1/hooks")
            return response.hooks ?? []
        case .plugins:
            let response: CatalogList = try await get("/api/v1/plugins")
            return response.plugins ?? []
        }
    }

    public func createSession(_ request: NewSessionRequest) async throws -> SessionSummary {
        let response: SessionEnvelope = try await post("/api/v1/sessions", json: request.body)
        return response.session
    }

    public func updateModel(_ id: Int, model: String) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionEnvelope = try await patch("/api/v1/sessions/\(segment)/model", json: ["model": model])
        return response.session
    }

    public func updateSelection(_ id: Int, _ kind: CatalogKind, to values: [String]) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionEnvelope
        switch kind {
        case .mcpServers: response = try await patch("/api/v1/sessions/\(segment)/mcp_servers", json: ["mcp_servers": values])
        case .skills: response = try await patch("/api/v1/sessions/\(segment)/catalog_skills", json: ["catalog_skills": values])
        case .hooks: response = try await patch("/api/v1/sessions/\(segment)/catalog_hooks", json: ["catalog_hooks": values])
        case .plugins: response = try await patch("/api/v1/sessions/\(segment)/catalog_plugins", json: ["catalog_plugins": values])
        }
        return response.session
    }
}

struct CatalogList: Decodable {
    let mcp_servers: [CatalogItem]?
    let skills: [CatalogItem]?
    let hooks: [CatalogItem]?
    let plugins: [CatalogItem]?
}
