import Foundation

/// A link to a page of the Zimmer the app is signed in to, as the screen that shows it here.
///
/// Agents write full session URLs into every message, so a transcript is full of links to
/// this deployment's own pages. Tapped in the app, one of those opens the app's screen for
/// that page rather than the web UI in a browser. A link to another host, or to a page the
/// app has no screen for, is not a `ZimmerLink` and opens as any link does.
public enum ZimmerLink: Hashable, Sendable {
    /// `/`, `/sessions`: the board.
    case board
    /// `/sessions/<id>`.
    case session(Int)
    /// `/sessions/<slug>`: the web UI spells a session's page with its slug when it has one.
    case sessionSlug(String)
    /// `/sessions/new`.
    case newSession
    /// `/notifications`.
    case inbox
    /// `/triggers`.
    case triggers
    /// `/triggers/<id>`.
    case trigger(Int)
    /// `/costs`, narrowed by `agent_root` or `session_id` as the web page is.
    case costs(CostScope)
    /// `/health`.
    case health
    /// `/clis`.
    case clis
    /// `/settings`.
    case settings
    /// `/settings/api_keys`.
    case apiKeys
    /// `/live`.
    case live

    /// The page `url` names, when it is on `origins` — either of them, since a link may have
    /// been written against the app host — and the app has a screen for it.
    public init?(url: URL, origins: ServerOrigins) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              [origins.web, origins.api].contains(where: { Self.sameOrigin(components, $0) })
        else { return nil }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        switch (segments.first, segments.dropFirst().first, segments.count) {
        case (nil, _, 0), ("sessions", _, 1): self = .board
        case ("sessions", "new", 2): self = .newSession
        case let ("sessions", segment?, 2):
            if let id = Int(segment), id > 0 {
                self = .session(id)
            } else if Self.isSlug(segment) {
                self = .sessionSlug(segment)
            } else {
                return nil
            }
        case ("notifications", _, 1): self = .inbox
        case ("triggers", _, 1): self = .triggers
        case let ("triggers", segment?, 2):
            guard let id = Int(segment), id > 0 else { return nil }
            self = .trigger(id)
        case ("costs", _, 1):
            if let root = query["agent_root"], !root.isEmpty {
                self = .costs(.agentRoot(root))
            } else if let id = query["session_id"].flatMap(Int.init) {
                self = .costs(.session(id))
            } else {
                self = .costs(.fleet)
            }
        case ("health", _, 1): self = .health
        case ("clis", _, 1): self = .clis
        case ("settings", _, 1): self = .settings
        case ("settings", "api_keys", 2): self = .apiKeys
        case ("live", _, 1): self = .live
        default: return nil
        }
    }

    /// Same host, ignoring case, and same port, an absent port being https's 443.
    private static func sameOrigin(_ link: URLComponents, _ origin: URL) -> Bool {
        guard let host = link.host?.lowercased(), let originHost = origin.host?.lowercased(), host == originHost else { return false }
        return (link.port ?? 443) == (origin.port ?? 443)
    }

    /// A session slug as the server validates one: lowercase letters, digits and hyphens, and
    /// not digits alone, which the server reads as an id.
    private static func isSlug(_ segment: String) -> Bool {
        let allowed = segment.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        return allowed && !segment.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
}
