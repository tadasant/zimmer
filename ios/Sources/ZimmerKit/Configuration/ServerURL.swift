import Foundation

/// A Zimmer server, as the app accepts one: an https origin and nothing else.
///
/// https only, because the access token travels on every request; no path, because every
/// route the app calls is absolute from the origin. The same rule `ios/bin/build-app`
/// applies to `--api-base-url`, so a build and a typed-in value cannot disagree.
public enum ServerURL {
    public static func parse(_ raw: String?) -> URL? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        return components.url
    }
}

/// The two origins a deployment can split Zimmer across.
///
/// `web` is where a person signs in: `/oauth/authorize` runs there, and it is the OAuth
/// issuer, so the `resource` and `iss` the app checks are built from it. `api` is where
/// every machine call goes — `/oauth/token`, `/oauth/revoke` and `/api/v1` — which on a
/// deployment with an app hostname behind its own access proxy is a different host. On a
/// deployment without one they are the same origin.
public struct ServerOrigins: Codable, Hashable, Sendable {
    public var web: URL
    public var api: URL

    public init(web: URL, api: URL? = nil) {
        self.web = web
        self.api = api ?? web
    }

    /// Whether machine calls go to a separate app host, which is when the edge login runs.
    public var isSplit: Bool { web != api }
}
