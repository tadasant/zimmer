import Foundation

/// The web UI's two buttons that stand for a person's decision: Merge (the sign-off that lets
/// a session merge its own PR) and Reprioritize (hand the board to the reprioritizing
/// session). The server takes both only from the app, and only on a sign-in that acts as
/// you. A relay-only one gets a 403 that says so.
public protocol DecisionsAPI: Sendable {
    /// Tell the session it may merge its open, green PR. A second tap answers `alreadySent`.
    func authorizeMerge(_ id: Int) async throws -> MergeAuthorization
    /// Ask the deployment's reprioritizing session to re-rank the board.
    func reprioritize() async throws -> Reprioritization
}

public struct MergeAuthorization: Hashable, Sendable {
    public var alreadySent: Bool
    public var message: String

    public init(alreadySent: Bool, message: String) {
        self.alreadySent = alreadySent
        self.message = message
    }
}

/// The session that took the job, and what the server said.
public struct Reprioritization: Hashable, Sendable {
    public var sessionID: Int
    public var message: String

    public init(sessionID: Int, message: String) {
        self.sessionID = sessionID
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

    public func reprioritize() async throws -> Reprioritization {
        let response: DecisionResponse = try await post("/api/v1/sessions/reprioritize", json: [:])
        guard let session = response.session else { throw ZimmerError.decoding("reprioritize: no session in a fired answer") }
        return Reprioritization(sessionID: session.id, message: response.message ?? "Reprioritizing.")
    }
}

struct DecisionResponse: Decodable {
    let outcome: String?
    let message: String?
    let session: SessionSummary?
}
