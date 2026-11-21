import Foundation

/// A Zimmer server, as the app accepts one: an https origin and nothing else.
///
/// https only, because the access token travels on every request; no path, because every
/// route the app calls is absolute from the origin. The same rule `ios/bin/build-app`
/// applies to `--api-base-url`, so a build and a typed-in value cannot disagree.
public enum ServerURL {
    public static func parse(_ raw: String?) -> URL? {
        let trimmed = clean(raw)
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

    /// What a person typed or pasted, with every character no address can contain taken out:
    /// whitespace and line breaks anywhere (a paste can carry a trailing newline, or break across
    /// lines), and the invisible format characters a copy from a web page or a chat brings along —
    /// zero-width spaces, a word joiner, a byte-order mark, direction marks. The zero-width joiner
    /// and non-joiner stay: internationalised host names in some scripts legitimately carry them,
    /// and taking them out would sign in to a different host.
    public static func clean(_ raw: String?) -> String {
        String((raw ?? "").unicodeScalars.filter { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
            if scalar == "\u{200C}" || scalar == "\u{200D}" { return true }
            return scalar.properties.generalCategory != .format
        })
    }
}

extension ServerURL {
    /// `base` + `path`, with exactly one slash between every segment.
    ///
    /// The one way the app joins a path onto an origin. An app host's tunnel answers 404 to
    /// any path containing `//`, so a base with a trailing slash, or a path with a leading
    /// one, must never produce one.
    public static func join(_ base: URL, _ path: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let segments = (components.percentEncodedPath + "/" + path).split(separator: "/", omittingEmptySubsequences: true)
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url!
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

    /// The origins a person typed, or what is wrong with them. An empty app host (after
    /// `ServerURL.clean`) means the same origin as the server.
    public static func parse(web rawWeb: String, api rawAPI: String) -> Result<ServerOrigins, ZimmerError> {
        guard let web = ServerURL.parse(rawWeb) else {
            return .failure(.signIn("Enter the https address of your Zimmer, like https://zimmer.example.com."))
        }
        let cleanedAPI = ServerURL.clean(rawAPI)
        guard !cleanedAPI.isEmpty else { return .success(ServerOrigins(web: web)) }
        guard let api = ServerURL.parse(cleanedAPI) else {
            return .failure(.signIn("The app host must be an https address too, or left empty."))
        }
        return .success(ServerOrigins(web: web, api: api))
    }
}
