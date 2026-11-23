import Foundation

/// The web UI's Merge button: the sign-off that lets a session merge its own PR. It is a
/// person's sign-off, so the server takes it only from the app, and only on a sign-in that
/// acts as you; a relay-only one gets a 403 that says so.
public protocol DecisionsAPI: Sendable {
    /// Tell the session it may merge its open, green PR. A second tap answers `alreadySent`.
    func authorizeMerge(_ id: Int) async throws -> MergeAuthorization
}

public struct MergeAuthorization: Hashable, Sendable {
    public var alreadySent: Bool
    public var message: String

    public init(alreadySent: Bool, message: String) {
        self.alreadySent = alreadySent
        self.message = message
    }
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `DecisionsAPI`.
extension ZimmerHTTPClient {
    public func authorizeMerge(_ id: Int) async throws -> MergeAuthorization {
        let segment = ZimmerPathComponent(String(id))
        let response: DecisionResponse = try await post("/api/v1/sessions/\(segment)/authorize_merge", json: [:])
        return MergeAuthorization(alreadySent: response.outcome == "already_sent", message: response.message ?? "Merge authorized.")
    }
}

struct DecisionResponse: Decodable {
    let outcome: String?
    let message: String?
}
