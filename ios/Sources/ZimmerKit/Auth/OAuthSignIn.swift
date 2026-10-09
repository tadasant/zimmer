import Foundation

/// Signing the app in to Zimmer, through Zimmer's own OAuth 2.1 authorization server.
///
/// The phone is a public OAuth client — the built-in `zimmer-ios` client
/// (`app/services/oauth_server/native_app.rb`). It opens `/oauth/authorize` in the system
/// sign-in sheet, where Zimmer's web sign-in wall does the work (Google, restricted to the
/// deployment's domain, then the second factor) and shows a consent screen. Approving sends
/// the sheet to `com.tadasant.zimmer:/oauth/callback?code=…&state=…`, and the app trades
/// that 60-second code, with the PKCE verifier only it holds, for an access token and a
/// refresh token. No Google credential and no API key ever reaches the phone, and the grant
/// is revoked from Settings → API keys like any other connection.
///
/// This type is the protocol half and does no I/O of its own beyond `HTTPTransport`; the
/// sheet is the app's (`ASWebAuthenticationSession`).
public struct OAuthSignIn: Sendable {
    public static let clientID = "zimmer-ios"
    public static let callbackScheme = "com.tadasant.zimmer"
    public static let redirectURI = "com.tadasant.zimmer:/oauth/callback"
    public static let scope = "mcp"

    public let baseURL: URL
    public let pkce: PKCEPair
    public let state: String

    public init(baseURL: URL, pkce: PKCEPair = .generate(), state: String = PKCEPair.randomState()) {
        self.baseURL = baseURL
        self.pkce = pkce
        self.state = state
    }

    /// The RFC 8707 resource every Zimmer token is bound to.
    public var resource: String {
        baseURL.appendingPathComponent("mcp").absoluteString
    }

    /// The URL to open in the sign-in sheet.
    public var authorizeURL: URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "scope", value: Self.scope),
        ]
        return components.url!
    }

    /// The code from the callback the sheet returned, after checking it is ours.
    ///
    /// `state` must match, or it is somebody else's callback. `iss`, when the server sends
    /// it (RFC 9207), must be the server this sign-in started at.
    public func code(fromCallback url: URL) throws -> String {
        guard url.scheme == Self.callbackScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { throw ZimmerError.signIn("Sign-in came back to the wrong place.") }
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })

        guard query["state"] == state else {
            throw ZimmerError.signIn("Sign-in came back for a different request. Try again.")
        }
        if let error = query["error"] {
            throw ZimmerError.signIn(error == "access_denied" ? "Sign-in was declined." : (query["error_description"] ?? error))
        }
        if let issuer = query["iss"], Self.origin(of: URL(string: issuer)) != Self.origin(of: baseURL) {
            throw ZimmerError.signIn("Sign-in came back from a different server.")
        }
        guard let code = query["code"], !code.isEmpty else {
            throw ZimmerError.signIn("Sign-in came back without a code.")
        }
        return code
    }

    /// The token request for the code.
    public func tokenRequest(code: String) -> HTTPRequest {
        Self.formRequest(baseURL: baseURL, fields: [
            "grant_type": "authorization_code",
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "redirect_uri": Self.redirectURI,
            "resource": resource,
        ])
    }

    public static func refreshRequest(baseURL: URL, refreshToken: String) -> HTTPRequest {
        formRequest(baseURL: baseURL, fields: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
        ])
    }

    public static func revokeRequest(baseURL: URL, token: String) -> HTTPRequest {
        var request = formRequest(baseURL: baseURL, fields: ["client_id": clientID, "token": token])
        request.url = baseURL.appendingPathComponent("oauth/revoke")
        return request
    }

    static func formRequest(baseURL: URL, fields: [String: String]) -> HTTPRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.keys.sorted().map { key in
            "\(key)=\(fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return HTTPRequest(
            url: baseURL.appendingPathComponent("oauth/token"),
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Data(body.utf8)
        )
    }

    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}

/// What the token endpoint returns.
public struct OAuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    struct Wire: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
    }

    static func decode(_ body: Data, now: Date) throws -> OAuthTokens {
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: body)
            return OAuthTokens(
                accessToken: wire.access_token,
                refreshToken: wire.refresh_token,
                expiresAt: now.addingTimeInterval(TimeInterval(wire.expires_in ?? 3600))
            )
        } catch {
            throw ZimmerError.decoding("token response: \(error)")
        }
    }

    /// Refresh this far ahead of expiry, so a request in flight does not race it.
    public func needsRefresh(at now: Date) -> Bool {
        now.addingTimeInterval(60) >= expiresAt
    }
}

/// The OAuth error body (RFC 6749 §5.2).
struct OAuthErrorBody: Decodable {
    let error: String
    let error_description: String?
}
