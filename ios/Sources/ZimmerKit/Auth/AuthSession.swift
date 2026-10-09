import Foundation

/// Where the signed-in state lives between launches. The app's is the Keychain
/// (`ZimmerPlatform.KeychainTokenStore`); tests use memory.
public protocol TokenStore: Sendable {
    func load() -> StoredSignIn?
    func save(_ signIn: StoredSignIn?)
}

/// A sign-in, as persisted: the server it is for and the tokens it holds.
public struct StoredSignIn: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var tokens: OAuthTokens

    public init(baseURL: URL, tokens: OAuthTokens) {
        self.baseURL = baseURL
        self.tokens = tokens
    }
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredSignIn?

    public init(_ value: StoredSignIn? = nil) { self.value = value }

    public func load() -> StoredSignIn? { lock.withLock { value } }
    public func save(_ signIn: StoredSignIn?) { lock.withLock { value = signIn } }
}

/// The one owner of the access token: hands it out, refreshes it before it expires, and
/// forgets it when the server says the grant is gone.
///
/// An actor, so two requests that both find the token stale make one refresh between them
/// rather than two — Zimmer rotates refresh tokens and treats a replay outside a short grace
/// window as theft, revoking the grant.
public actor AuthSession {
    private let store: TokenStore
    private let transport: HTTPTransport
    private let edge: EdgeCredential
    private let now: @Sendable () -> Date
    private var current: StoredSignIn?
    private var refreshing: Task<OAuthTokens, Error>?

    public init(
        store: TokenStore,
        transport: HTTPTransport,
        edge: EdgeCredential = NoEdgeCredential(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.transport = transport
        self.edge = edge
        self.now = now
        self.current = store.load()
    }

    public var signIn: StoredSignIn? { current }
    public var isSignedIn: Bool { current != nil }

    /// Finish a sign-in the sheet returned from.
    public func complete(_ flow: OAuthSignIn, callback: URL) async throws {
        let code = try flow.code(fromCallback: callback)
        let tokens = try await exchange(flow.tokenRequest(code: code))
        current = StoredSignIn(baseURL: flow.baseURL, tokens: tokens)
        store.save(current)
    }

    /// A valid access token, refreshed first if it is about to expire.
    public func accessToken() async throws -> String {
        guard let signIn = current else { throw ZimmerError.unauthorized }
        if !signIn.tokens.needsRefresh(at: now()) { return signIn.tokens.accessToken }
        return try await refresh().accessToken
    }

    /// Refresh now — after a 401 on a token that had not yet expired by the clock.
    @discardableResult
    public func refresh() async throws -> OAuthTokens {
        if let refreshing { return try await refreshing.value }
        guard let signIn = current, let refreshToken = signIn.tokens.refreshToken else {
            signOutLocally()
            throw ZimmerError.unauthorized
        }
        let task = Task { try await self.exchange(OAuthSignIn.refreshRequest(baseURL: signIn.baseURL, refreshToken: refreshToken)) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let tokens = try await task.value
            current = StoredSignIn(baseURL: signIn.baseURL, tokens: tokens)
            store.save(current)
            return tokens
        } catch ZimmerError.unauthorized {
            signOutLocally()
            throw ZimmerError.unauthorized
        }
    }

    /// Revoke the grant on the server (best effort) and forget it here.
    public func signOut() async {
        if let signIn = current, let token = signIn.tokens.refreshToken {
            var request = OAuthSignIn.revokeRequest(baseURL: signIn.baseURL, token: token)
            await edge.decorate(&request)
            _ = try? await transport.send(request)
        }
        signOutLocally()
    }

    public func signOutLocally() {
        current = nil
        store.save(nil)
    }

    private func exchange(_ request: HTTPRequest) async throws -> OAuthTokens {
        var attempt = 0
        while true {
            var decorated = request
            await edge.decorate(&decorated)
            let response: HTTPResponse
            do {
                response = try await transport.send(decorated)
            } catch {
                throw ZimmerError.transport(error)
            }
            if EdgeRefusal.isEdgeRefusal(response) {
                if attempt == 0, await edge.reauthenticate() { attempt += 1; continue }
                throw ZimmerError.edgeRefused
            }
            switch response.statusCode {
            case 200..<300:
                return try OAuthTokens.decode(response.body, now: now())
            case 400, 401:
                // `invalid_grant` is the grant being gone: revoked, replayed, or the
                // refresh token expired. Nothing to do but sign in again.
                let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: response.body)
                if body?.error == "invalid_grant" || response.statusCode == 401 { throw ZimmerError.unauthorized }
                throw ZimmerError.http(status: response.statusCode, message: body?.error_description ?? body?.error)
            default:
                throw ZimmerError.http(status: response.statusCode, message: nil)
            }
        }
    }
}
