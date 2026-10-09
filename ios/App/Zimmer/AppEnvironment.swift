import Foundation
import ZimmerKit
import ZimmerPlatform

/// The one place the real adapters are chosen.
///
/// A singleton rather than a SwiftUI environment object because the app delegate (push
/// registration) and the CarPlay scene cannot receive environment objects, and they must
/// talk to the same signed-in session as the screens.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    /// Everything that talks to one deployment. Rebuilt when the deployment changes,
    /// because whether there is an edge login at all depends on its origins.
    struct Connection {
        let origins: ServerOrigins?
        let auth: AuthSession
        let api: ZimmerAPI
        /// The Cloudflare Access login for a deployment whose machine calls go to a
        /// separate app host; nil when web and app are one origin.
        let edge: CloudflareAccessCredential?
    }

    let configuration = AppConfiguration()
    private(set) var connection: Connection
    /// True when a `#if DEBUG` launch argument swapped in the in-memory fake.
    let isFixture: Bool

    private let transport = URLSessionTransport()
    private let tokenStore: TokenStore
    private let edgeStore: EdgeTokenStore

    private init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ZimmerFixture") {
            // Screens with no server and no sign-in, for the UI test and screenshots: an
            // agent cannot complete a Google sign-in. `-ZimmerFixtureSignedOut` shows the
            // sign-in screen instead of the list.
            let origins = AppConfiguration.buildDefaultOrigins ?? ServerOrigins(web: URL(string: "https://fixture.invalid")!)
            let signedIn = arguments.contains("-ZimmerFixtureSignedOut")
                ? nil
                : StoredSignIn(origins: origins, tokens: OAuthTokens(accessToken: "fixture", refreshToken: nil, expiresAt: .distantFuture))
            tokenStore = InMemoryTokenStore(signedIn)
            edgeStore = InMemoryEdgeTokenStore()
            let auth = AuthSession(store: tokenStore, transport: transport)
            connection = Connection(origins: signedIn?.origins, auth: auth, api: FakeZimmerAPI(), edge: nil)
            isFixture = true
            return
        }
        #endif

        tokenStore = KeychainTokenStore()
        edgeStore = KeychainEdgeTokenStore()
        isFixture = false
        connection = Self.makeConnection(origins: tokenStore.load()?.origins, transport: transport, tokenStore: tokenStore, edgeStore: edgeStore)
    }

    /// Point everything at `origins` — before a sign-in, so its token call carries the
    /// edge's credential.
    func connect(to origins: ServerOrigins) -> Connection {
        guard !isFixture else { return connection }
        if origins != connection.origins {
            if origins.api != connection.origins?.api { edgeStore.save(nil) }
            connection = Self.makeConnection(origins: origins, transport: transport, tokenStore: tokenStore, edgeStore: edgeStore)
        }
        return connection
    }

    private static func makeConnection(
        origins: ServerOrigins?, transport: HTTPTransport, tokenStore: TokenStore, edgeStore: EdgeTokenStore
    ) -> Connection {
        let edge = origins.flatMap { origins in
            origins.isSplit
                ? CloudflareAccessCredential(apiBaseURL: origins.api, store: edgeStore, presenter: WebAuthPresenter.presenter)
                : nil
        }
        let edgeCredential: EdgeCredential = edge ?? NoEdgeCredential()
        let auth = AuthSession(store: tokenStore, transport: transport, edge: edgeCredential)
        let api = ZimmerHTTPClient(auth: auth, transport: transport, edge: edgeCredential)
        return Connection(origins: origins, auth: auth, api: api, edge: edge)
    }
}
