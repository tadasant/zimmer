import Foundation

/// Whatever the network edge in front of Zimmer wants from this phone, kept apart from
/// Zimmer's own credential.
///
/// A deployment can put an access proxy in front of Rails — Tadas's production one sits
/// behind Cloudflare Access — and that proxy may refuse a request before Zimmer ever sees
/// it. What it accepts is a property of the deployment, not of the app, and it is not
/// settled yet, so the app does not assume an answer: every request (the OAuth token calls
/// as well as the API calls) passes through `decorate`, and a refusal that came from the
/// edge rather than from Zimmer is handed to `reauthenticate`.
///
/// **Never a shared secret.** The repository and the TestFlight build are effectively
/// public; a service token compiled into the app is a service token published. A
/// conforming type must hold a credential this one phone obtained for itself.
public protocol EdgeCredential: Sendable {
    /// Add whatever headers or cookies the edge needs to one request.
    func decorate(_ request: inout HTTPRequest) async
    /// The edge refused a request. Return true if a credential was renewed and the request
    /// is worth sending once more; false if nothing could be done.
    func reauthenticate() async -> Bool
}

/// The default: the edge wants nothing, and a refusal cannot be fixed from here.
public struct NoEdgeCredential: EdgeCredential {
    public init() {}
    public func decorate(_ request: inout HTTPRequest) async {}
    public func reauthenticate() async -> Bool { false }
}

public enum EdgeRefusal {
    /// Whether a 401/403 came from an access proxy rather than from Zimmer.
    ///
    /// Zimmer's own refusals are JSON in its error envelope. Cloudflare Access answers with
    /// an HTML page, `server: cloudflare`, and a `cf-access-aud` header naming the Access
    /// application; any one of the Access markers is enough, and a non-JSON body from
    /// Cloudflare is the fallback for a proxy that omits them.
    public static func isEdgeRefusal(_ response: HTTPResponse) -> Bool {
        guard response.statusCode == 401 || response.statusCode == 403 else { return false }
        let headers = Dictionary(uniqueKeysWithValues: response.headers.map { ($0.key.lowercased(), $0.value) })
        if headers["cf-access-aud"] != nil || headers["cf-access-domain"] != nil { return true }
        let server = headers["server"]?.lowercased() ?? ""
        let contentType = headers["content-type"]?.lowercased() ?? ""
        return server.contains("cloudflare") && !contentType.contains("json")
    }
}
