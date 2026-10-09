import Foundation

/// One operation: a method, a path, and its query.
///
/// `ZimmerHTTPClient` is the only place these are constructed, which is what keeps a
/// hand-typed URL from appearing anywhere in the app.
public struct HTTPEndpoint: Hashable, Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]

    public init(method: String, path: String, query: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.query = query
    }

    /// Resolve against a base URL. Returns nil only if the base is not a valid URL.
    ///
    /// `path` already carries escaped components, so it is joined textually — through
    /// `ServerURL.join`, which also guarantees no `//` — rather than through
    /// `appendingPathComponent`, which would escape the escapes.
    public func url(relativeTo base: URL) -> URL? {
        guard var components = URLComponents(url: ServerURL.join(base, path), resolvingAgainstBaseURL: false)
        else { return nil }
        if !query.isEmpty {
            components.queryItems = query.keys.sorted().map {
                URLQueryItem(name: $0, value: query[$0])
            }
        }
        return components.url
    }
}

/// A path parameter, escaped for interpolation into a URL path.
///
/// Paths interpolate `\(ZimmerPathComponent(id))` rather than the raw value: a session can
/// be addressed by slug, and one containing a `/` or a `?` would otherwise rewrite the
/// route it was meant to fill in.
public struct ZimmerPathComponent: CustomStringConvertible, Sendable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String {
        value.addingPercentEncoding(withAllowedCharacters: .zimmerPathComponent) ?? value
    }
}

extension CharacterSet {
    /// RFC 3986 `pchar` minus the sub-delims that would still be ambiguous in a path.
    fileprivate static let zimmerPathComponent: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}
