import Foundation

/// The auth boundary (`Api::V1::AccountController`, `OauthGrantsController`,
/// `ApiKeysController`): who the token is, the deployment's connections and keys, and the
/// writes the Settings pages offer on them. The reads take any sign-in; every write takes one
/// acting as you, and a relay-only grant gets a 403 with the rule in its message.
public protocol AccountAPI: Sendable {
    /// `GET /me`: who the token is, the Sign-in card, and Deployment Information.
    func account() async throws -> Account
    /// `GET /oauth_grants`: every connection on the deployment, active first; the caller's
    /// own flagged `current`.
    func oauthGrants() async throws -> [OAuthGrant]
    /// `PATCH /oauth_grants/:id`: the page's *Make relay only* / *Let it act on my behalf*.
    func setGrantPrivilege(_ id: Int, actsAsYou: Bool) async throws -> OAuthGrant
    /// `DELETE /oauth_grants/:id`: revoke a connection; the caller's own is a sign-out.
    func revokeGrant(_ id: Int) async throws -> GrantRevocation
    /// `GET /api_keys`: every key on the deployment, active first, newest first.
    func apiKeys() async throws -> [APIKey]
    /// `POST /api_keys`: mint a named key; the token in the answer is its only copy.
    func mintAPIKey(name: String, grant: String) async throws -> MintedAPIKey
    /// `DELETE /api_keys/:id`: revoke; the row stays so `restoreAPIKey` can undo it.
    func revokeAPIKey(_ id: Int) async throws -> APIKey
    /// `POST /api_keys/:id/restore`: a revoked key authenticates again at once.
    func restoreAPIKey(_ id: Int) async throws -> APIKey
    /// `POST /sign_out_everywhere`: end every web sign-in as the caller, and the caller's own
    /// connection with them — the app has to sign in again afterwards.
    func signOutEverywhere() async throws -> SignOutEverywhereResult
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `AccountAPI`.
extension ZimmerHTTPClient {
    public func account() async throws -> Account {
        try await get("/api/v1/me")
    }

    public func oauthGrants() async throws -> [OAuthGrant] {
        let response: OAuthGrantsEnvelope = try await get("/api/v1/oauth_grants")
        return response.oauth_grants
    }

    public func setGrantPrivilege(_ id: Int, actsAsYou: Bool) async throws -> OAuthGrant {
        let segment = ZimmerPathComponent(String(id))
        let privilege = actsAsYou ? OAuthGrant.actAsHuman : OAuthGrant.relayOnly
        let response: OAuthGrantEnvelope = try await patch("/api/v1/oauth_grants/\(segment)", json: ["privilege": privilege])
        return response.oauth_grant
    }

    public func revokeGrant(_ id: Int) async throws -> GrantRevocation {
        let segment = ZimmerPathComponent(String(id))
        let response: OAuthGrantEnvelope = try await delete("/api/v1/oauth_grants/\(segment)")
        return GrantRevocation(grant: response.oauth_grant, signedOut: response.signed_out ?? false, message: response.message ?? "Revoked.")
    }

    public func apiKeys() async throws -> [APIKey] {
        let response: APIKeysEnvelope = try await get("/api/v1/api_keys")
        return response.api_keys
    }

    public func mintAPIKey(name: String, grant: String) async throws -> MintedAPIKey {
        let response: APIKeyEnvelope = try await post("/api/v1/api_keys", json: ["name": name, "grant": grant])
        // Worded without the path: a literal starting with the API prefix reads as a route the app
        // calls (test/config/native_app_api_coverage_test.rb).
        guard let token = response.token else { throw ZimmerError.decoding("minting a key: no token in the answer") }
        return MintedAPIKey(key: response.api_key, token: token)
    }

    public func revokeAPIKey(_ id: Int) async throws -> APIKey {
        let segment = ZimmerPathComponent(String(id))
        let response: APIKeyEnvelope = try await delete("/api/v1/api_keys/\(segment)")
        return response.api_key
    }

    public func restoreAPIKey(_ id: Int) async throws -> APIKey {
        let segment = ZimmerPathComponent(String(id))
        let response: APIKeyEnvelope = try await post("/api/v1/api_keys/\(segment)/restore", json: [:])
        return response.api_key
    }

    public func signOutEverywhere() async throws -> SignOutEverywhereResult {
        let response: SignOutEverywhereResponse = try await post("/api/v1/sign_out_everywhere", json: [:])
        return SignOutEverywhereResult(webSignInsEnded: response.web_sign_ins_ended ?? 0,
                                       thisConnectionRevoked: response.this_connection_revoked ?? true,
                                       message: response.message ?? "Signed out on every device.")
    }

    /// A DELETE whose answer is read: the two revokes here return the row they revoked.
    func delete<T: Decodable>(_ path: String) async throws -> T {
        let response = try await perform(method: "DELETE", path: path, query: [:], body: nil)
        do {
            return try ZimmerJSON.decoder.decode(T.self, from: response.body)
        } catch {
            throw ZimmerError.decoding("\(path): \(error)")
        }
    }
}

struct OAuthGrantsEnvelope: Decodable {
    let oauth_grants: [OAuthGrant]
}

struct OAuthGrantEnvelope: Decodable {
    let oauth_grant: OAuthGrant
    let signed_out: Bool?
    let message: String?
}

struct APIKeysEnvelope: Decodable {
    let api_keys: [APIKey]
}

struct APIKeyEnvelope: Decodable {
    let api_key: APIKey
    let token: String?
    let message: String?
}

struct SignOutEverywhereResponse: Decodable {
    let signed_out_everywhere: Bool?
    let web_sign_ins_ended: Int?
    let this_connection_revoked: Bool?
    let message: String?
}
