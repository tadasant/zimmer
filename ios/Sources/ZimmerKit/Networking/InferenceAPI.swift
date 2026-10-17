import Foundation

/// The web UI's Inference page over REST: the read any key may make, and the writes that
/// take only the app's sign-in on a grant that acts as you — the operator's levers over
/// which account the fleet runs on and how much work it does. A relay-only grant gets 403
/// on every write, with the server's sentence, having changed nothing.
public protocol InferenceAPI: Sendable {
    /// The page for one runtime (`claude_code`, `codex` or `pi`).
    func inference(runtime: String) async throws -> InferenceReport
    /// The Add account form. `apiKey` is Codex only; an OAuth account is created with no
    /// credentials and needs a login.
    func addInferenceAccount(runtime: String, email: String, priority: Int, apiKey: String?) async throws -> InferenceAccountChange
    /// Re-probe one account's quota; a failed probe rides back as `account.probeError`.
    func refreshInferenceAccount(_ id: Int) async throws -> InferenceAccountRefresh
    /// The Switch button: make it the current account.
    func activateInferenceAccount(_ id: Int) async throws -> InferenceAccountChange
    func deleteInferenceAccount(_ id: Int) async throws -> InferenceAccountRemoval
    /// The Authenticate button: start the login CLI in the worker for the account.
    func startInferenceLogin(accountID: Int) async throws -> LoginAttempt
    /// Poll an attempt. 404 once it is pruned or its account deleted: stop polling.
    func inferenceLogin(_ id: Int) async throws -> LoginPoll
    /// The Claude flow: hand the authorization code the page showed to the CLI.
    func submitInferenceLoginCode(_ id: Int, code: String) async throws -> LoginAttempt
    func cancelInferenceLogin(_ id: Int) async throws -> LoginAttempt
    func updateSpotPolicy(_ change: SpotPolicyChange) async throws -> SpotPolicy
    func updateFleetTopUp(_ change: FleetTopUpChange) async throws -> FleetTopUp
    /// Make a genesis kind `spot` or `priority`; every session deriving its class from that
    /// kind moves at once.
    func setGenesisClass(_ genesis: String, to priorityClass: String) async throws -> GenesisClassChange
    func resetGenesisClasses() async throws -> GenesisClassChange
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `InferenceAPI`.
extension ZimmerHTTPClient {
    public func inference(runtime: String) async throws -> InferenceReport {
        try await get("/api/v1/inference", query: ["runtime": runtime])
    }

    public func addInferenceAccount(runtime: String, email: String, priority: Int, apiKey: String?) async throws -> InferenceAccountChange {
        var json: [String: Any] = ["runtime": runtime, "email": email, "priority": priority]
        if let apiKey, !apiKey.isEmpty { json["api_key"] = apiKey }
        return try await post("/api/v1/inference/accounts", json: json)
    }

    public func refreshInferenceAccount(_ id: Int) async throws -> InferenceAccountRefresh {
        try await post("/api/v1/inference/accounts/\(id)/refresh", json: [:])
    }

    public func activateInferenceAccount(_ id: Int) async throws -> InferenceAccountChange {
        try await post("/api/v1/inference/accounts/\(id)/activate", json: [:])
    }

    public func deleteInferenceAccount(_ id: Int) async throws -> InferenceAccountRemoval {
        try await delete("/api/v1/inference/accounts/\(id)")
    }

    public func startInferenceLogin(accountID: Int) async throws -> LoginAttempt {
        let response: LoginEnvelope = try await post("/api/v1/inference/logins", json: ["account_id": accountID])
        return response.login
    }

    public func inferenceLogin(_ id: Int) async throws -> LoginPoll {
        try await get("/api/v1/inference/logins/\(id)")
    }

    public func submitInferenceLoginCode(_ id: Int, code: String) async throws -> LoginAttempt {
        let response: LoginEnvelope = try await post("/api/v1/inference/logins/\(id)/code", json: ["code": code])
        return response.login
    }

    public func cancelInferenceLogin(_ id: Int) async throws -> LoginAttempt {
        let response: LoginEnvelope = try await post("/api/v1/inference/logins/\(id)/cancel", json: [:])
        return response.login
    }

    public func updateSpotPolicy(_ change: SpotPolicyChange) async throws -> SpotPolicy {
        let response: SpotPolicyEnvelope = try await patch("/api/v1/inference/spot_policy", json: change.json)
        return response.spot_policy
    }

    public func updateFleetTopUp(_ change: FleetTopUpChange) async throws -> FleetTopUp {
        let response: FleetTopUpEnvelope = try await patch("/api/v1/inference/fleet_top_up", json: change.json)
        return response.fleet_top_up
    }

    public func setGenesisClass(_ genesis: String, to priorityClass: String) async throws -> GenesisClassChange {
        let segment = ZimmerPathComponent(genesis)
        return try await patch("/api/v1/inference/genesis/\(segment)", json: ["priority_class": priorityClass])
    }

    public func resetGenesisClasses() async throws -> GenesisClassChange {
        // `delete(_:)` is the client's own, declared beside the account routes.
        try await delete("/api/v1/inference/genesis")
    }
}

struct LoginEnvelope: Decodable {
    let login: LoginAttempt
}

struct SpotPolicyEnvelope: Decodable {
    let spot_policy: SpotPolicy
}

struct FleetTopUpEnvelope: Decodable {
    let fleet_top_up: FleetTopUp
}
