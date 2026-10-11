import Foundation

/// What the app asks of Zimmer. A protocol so screens and tests can run against
/// `FakeZimmerAPI` with no server and no sign-in.
public protocol ZimmerAPI: SessionActionsAPI, SessionDetailExtrasAPI {
    func sessions(_ filter: SessionFilter) async throws -> [SessionSummary]
    func session(_ id: Int) async throws -> SessionDetail
    func conversation(_ id: Int) async throws -> Conversation
    func followUp(_ id: Int, prompt: String) async throws -> FollowUpResult
    func archive(_ id: Int) async throws -> SessionSummary
    /// Start a Quick Router session from a plain-language request; returns its id.
    func startQuickRouter(_ prompt: String) async throws -> Int
    /// Register this phone for push notifications (idempotent: an upsert on the token).
    func registerDevice(token: String, environment: APNsEnvironment, deviceName: String?, appVersion: String?) async throws
    /// Unregister it, on sign-out.
    func unregisterDevice(token: String) async throws
}

/// Zimmer's REST API (`/api/v1`), called with the signed-in grant's access token.
///
/// No Swift client is generated: Zimmer publishes no OpenAPI document, so the few
/// responses the app reads are decoded by hand-written `Codable` types whose fields beyond
/// the essentials are optional.
public struct ZimmerHTTPClient: ZimmerAPI {
    private let auth: AuthSession
    private let transport: HTTPTransport
    private let edge: EdgeCredential

    public init(auth: AuthSession, transport: HTTPTransport, edge: EdgeCredential = NoEdgeCredential()) {
        self.auth = auth
        self.transport = transport
        self.edge = edge
    }

    public func sessions(_ filter: SessionFilter) async throws -> [SessionSummary] {
        let response: SessionListResponse = try await get("/api/v1/sessions", query: filter.query)
        return SessionOrdering.sorted(response.sessions)
    }

    public func session(_ id: Int) async throws -> SessionDetail {
        let segment = ZimmerPathComponent(String(id))
        let response: SessionShowResponse = try await get("/api/v1/sessions/\(segment)")
        return SessionDetail(session: response.session, statusSummary: response.statusSummary, hierarchy: response.hierarchy)
    }

    public func conversation(_ id: Int) async throws -> Conversation {
        let segment = ZimmerPathComponent(String(id))
        let response: ConversationResponse = try await get("/api/v1/sessions/\(segment)/conversation", query: ["limit": "100"])
        return response.conversation
    }

    public func followUp(_ id: Int, prompt: String) async throws -> FollowUpResult {
        let segment = ZimmerPathComponent(String(id))
        let response: FollowUpResponse = try await post("/api/v1/sessions/\(segment)/follow_up", json: ["prompt": prompt])
        let queued = response.enqueued_message != nil
        return FollowUpResult(queued: queued, message: response.message ?? (queued ? "Queued" : "Sent"))
    }

    public func archive(_ id: Int) async throws -> SessionSummary {
        let segment = ZimmerPathComponent(String(id))
        let response: ArchiveResponse = try await post("/api/v1/sessions/\(segment)/archive", json: [:])
        return response.session
    }

    public func startQuickRouter(_ prompt: String) async throws -> Int {
        let response: QuickRouterResponse = try await post("/api/v1/quick_router", json: ["prompt": prompt])
        return response.session_id
    }

    public func registerDevice(token: String, environment: APNsEnvironment, deviceName: String?, appVersion: String?) async throws {
        var json: [String: Any] = ["token": token, "environment": environment.rawValue]
        if let deviceName { json["device_name"] = deviceName }
        if let appVersion { json["app_version"] = appVersion }
        let _: DeviceRegistration.Response = try await post("/api/v1/apns_devices", json: json)
    }

    public func unregisterDevice(token: String) async throws {
        let segment = ZimmerPathComponent(token)
        _ = try await perform(method: "DELETE", path: "/api/v1/apns_devices/\(segment)", query: [:], body: nil)
    }

    // MARK: - Plumbing

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(method: "GET", path: path, query: query, body: nil)
    }

    func post<T: Decodable>(_ path: String, json: [String: Any]) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return try await send(method: "POST", path: path, query: [:], body: body)
    }

    private func send<T: Decodable>(method: String, path: String, query: [String: String], body: Data?) async throws -> T {
        let response = try await perform(method: method, path: path, query: query, body: body)
        do {
            return try ZimmerJSON.decoder.decode(T.self, from: response.body)
        } catch {
            throw ZimmerError.decoding("\(path): \(error)")
        }
    }

    /// One call, with at most one retry for each of the two credentials that can be
    /// renewed: the edge's (an access proxy's refusal) and Zimmer's own (a 401 on a token
    /// the clock thought was still good, e.g. after the grant was refreshed elsewhere).
    func perform(method: String, path: String, query: [String: String], body: Data?) async throws -> HTTPResponse {
        guard let baseURL = await auth.signIn?.origins.api else { throw ZimmerError.unauthorized }
        guard let url = HTTPEndpoint(method: method, path: path, query: query).url(relativeTo: baseURL) else {
            throw ZimmerError.notConfigured
        }
        var retriedEdge = false
        var retriedToken = false
        while true {
            var request = HTTPRequest(url: url, method: method, headers: ["Accept": "application/json"], body: body)
            if body != nil { request.headers["Content-Type"] = "application/json" }
            request.headers["Authorization"] = "Bearer \(try await auth.accessToken())"
            await request.apply(edge)

            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                throw ZimmerError.transport(error)
            }

            if EdgeRefusal.isEdgeRefusal(response) {
                if !retriedEdge, await edge.reauthenticate() { retriedEdge = true; continue }
                throw ZimmerError.edgeRefused
            }
            if EdgeRefusal.isEdgeNotRouted(response) { throw ZimmerError.edgeNotRouted(path) }
            if response.statusCode == 401 {
                if !retriedToken { retriedToken = true; try await auth.refresh(); continue }
                await auth.signOutLocally()
                throw ZimmerError.unauthorized
            }
            guard (200..<300).contains(response.statusCode) else {
                let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: response.body)
                throw ZimmerError.http(status: response.statusCode, message: envelope?.message)
            }
            return response
        }
    }
}

public enum ZimmerJSON {
    /// Rails renders `iso8601` timestamps, with or without fractional seconds.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not ISO 8601: \(raw)"))
        }
        return decoder
    }()

    public static func parseDate(_ raw: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }
}
