import Foundation

/// Whatever the network edge in front of Zimmer wants from this phone, kept apart from
/// Zimmer's own credential.
///
/// A deployment can put an access proxy in front of Rails. Tadas's production one does:
/// the app's machine calls go to a separate app hostname behind Cloudflare Access, which
/// admits a request only if it carries the `cf-access-token` JWT the phone earned at its
/// own Access login (`CloudflareAccessCredential`). Every request — the OAuth token calls
/// as well as the API calls — gets `headers()`, and a refusal that came from the edge
/// rather than from Zimmer is handed to `reauthenticate()`.
///
/// **Never a shared secret.** The repository and the TestFlight build are effectively
/// public; a service token compiled into the app is a service token published. A
/// conforming type must hold a credential this one phone obtained for itself — and must
/// never put it in `Authorization`, which is Zimmer's.
public protocol EdgeCredential: Sendable {
    /// Headers the edge needs on one request.
    func headers() async -> [String: String]
    /// The edge refused a request. Return true if a credential was renewed and the request
    /// is worth sending once more; false if nothing could be done.
    func reauthenticate() async -> Bool
}

/// The default, for a deployment whose edge wants nothing.
public struct NoEdgeCredential: EdgeCredential {
    public init() {}
    public func headers() async -> [String: String] { [:] }
    public func reauthenticate() async -> Bool { false }
}

extension HTTPRequest {
    mutating func apply(_ edge: EdgeCredential) async {
        for (name, value) in await edge.headers() where name.lowercased() != "authorization" {
            headers[name] = value
        }
    }
}

public enum EdgeRefusal {
    /// The Access team domains, whose login pages a refused request is redirected to.
    static let accessLoginHostSuffix = ".cloudflareaccess.com"

    /// Whether a response is Cloudflare Access refusing the request, rather than Zimmer.
    ///
    /// Access refuses in one of two shapes: a redirect to its login page on
    /// `<team>.cloudflareaccess.com` (often with `www-authenticate: Cloudflare-Access …`),
    /// or a 401/403 HTML page carrying `cf-access-aud`. Zimmer's own 401 is JSON with an
    /// `x-request-id` and no `cf-access-aud`. `server: cloudflare` is on every response
    /// through the edge, so it says nothing.
    public static func isEdgeRefusal(_ response: HTTPResponse) -> Bool {
        let headers = lowercased(response.headers)
        if headers["www-authenticate"]?.lowercased().hasPrefix("cloudflare-access") == true { return true }
        if (300..<400).contains(response.statusCode),
           let location = headers["location"].flatMap(URL.init(string:)),
           isAccessLogin(location) {
            return true
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            return headers["cf-access-aud"] != nil || headers["cf-access-domain"] != nil
        }
        return false
    }

    /// A 404 from the edge's tunnel rather than from Rails: the path is not on the app
    /// host's allow-list. That is a bug in the edge or the app, never something to retry.
    public static func isEdgeNotRouted(_ response: HTTPResponse) -> Bool {
        let headers = lowercased(response.headers)
        return response.statusCode == 404
            && headers["x-request-id"] == nil
            && (headers["content-type"]?.lowercased().hasPrefix("text/plain") ?? false)
    }

    /// Whether a redirect leads to an Access login page, which a machine call must not
    /// follow: it would come back as a login page's HTML with a 200.
    public static func isAccessLogin(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(accessLoginHostSuffix)
    }

    static func lowercased(_ headers: [String: String]) -> [String: String] {
        Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
