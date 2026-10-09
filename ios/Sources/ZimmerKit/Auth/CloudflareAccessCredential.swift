import Foundation

/// Where the edge's JWT lives between launches. The app's is the Keychain.
public protocol EdgeTokenStore: Sendable {
    func load() -> String?
    func save(_ token: String?)
}

public final class InMemoryEdgeTokenStore: EdgeTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func load() -> String? { lock.withLock { value } }
    public func save(_ token: String?) { lock.withLock { value = token } }
}

/// The edge login: the phone's own Cloudflare Access credential for the app host.
///
/// The app host sits behind an Access application that admits only the deployment's
/// Google policy. The phone earns a JWT by opening `GET /native/access-handoff` on that
/// host in the system sign-in sheet: Access runs its Google login, Rails checks the
/// assertion Access forwarded and redirects to `com.tadasant.zimmer:/access/callback`
/// with it (`NativeAccessHandoffsController`). The app checks `state`, keeps the JWT in
/// the Keychain, and sends it as `cf-access-token` on every machine call.
///
/// The JWT lives about 30 days. Re-running the handoff *is* the refresh: proactively when
/// fewer than 24 hours are left (`refreshIfNeeded`), and reactively when the edge refuses a
/// request (`reauthenticate`).
public actor CloudflareAccessCredential: EdgeCredential {
    public static let callbackScheme = "com.tadasant.zimmer"
    public static let callbackPath = "/access/callback"
    public static let refreshWindow: TimeInterval = 24 * 60 * 60

    /// Opens a URL in the system sign-in sheet and returns the callback it ended on.
    public typealias Presenter = @Sendable (URL) async throws -> URL

    private let apiBaseURL: URL
    private let store: EdgeTokenStore
    private let presenter: Presenter
    private let now: @Sendable () -> Date
    private var inFlight: Task<String, Error>?

    public init(
        apiBaseURL: URL,
        store: EdgeTokenStore,
        presenter: @escaping Presenter,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiBaseURL = apiBaseURL
        self.store = store
        self.presenter = presenter
        self.now = now
    }

    public func headers() async -> [String: String] {
        guard let token = store.load() else { return [:] }
        return ["cf-access-token": token]
    }

    public func reauthenticate() async -> Bool {
        (try? await login()) != nil
    }

    /// Whether the stored JWT is missing or inside the refresh window.
    public func needsLogin() -> Bool {
        guard let token = store.load(), let expiry = Self.expiry(of: token) else { return true }
        return expiry.timeIntervalSince(now()) < Self.refreshWindow
    }

    /// Run the handoff if the stored JWT is missing or about to expire.
    public func refreshIfNeeded() async throws {
        if needsLogin() { _ = try await login() }
    }

    public func forget() {
        store.save(nil)
    }

    /// Run the handoff once, however many callers ask at the same time.
    @discardableResult
    public func login() async throws -> String {
        if let inFlight { return try await inFlight.value }
        let state = PKCEPair.randomState()
        let url = Self.handoffURL(apiBaseURL: apiBaseURL, state: state)
        let presenter = self.presenter
        let task = Task { try Self.token(fromCallback: try await presenter(url), state: state) }
        inFlight = task
        defer { inFlight = nil }
        let token = try await task.value
        store.save(token)
        return token
    }

    public static func handoffURL(apiBaseURL: URL, state: String) -> URL {
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("native/access-handoff"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        return components.url!
    }

    public static func token(fromCallback url: URL, state: String) throws -> String {
        guard url.scheme == callbackScheme, url.path == callbackPath,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { throw ZimmerError.signIn("The edge sign-in came back to the wrong place.") }
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard query["state"] == state else {
            throw ZimmerError.signIn("The edge sign-in came back for a different request. Try again.")
        }
        guard let token = query["cf_access_token"], !token.isEmpty, expiry(of: token) != nil else {
            throw ZimmerError.signIn("The edge sign-in came back without a usable token.")
        }
        return token
    }

    /// The JWT's `exp`, read without checking the signature — the edge checks it; the app
    /// only needs to know when to renew.
    public static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
