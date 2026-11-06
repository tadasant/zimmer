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
            // sign-in screen instead of the list; `-ZimmerFixtureRelayOnly` is a sign-in that
            // does not act as you, so Settings → MCP Apps is refused.
            let origins = AppConfiguration.buildDefaultOrigins ?? ServerOrigins(web: URL(string: "https://fixture.invalid")!)
            let signedIn = arguments.contains("-ZimmerFixtureSignedOut")
                ? nil
                : StoredSignIn(origins: origins, tokens: OAuthTokens(accessToken: "fixture", refreshToken: nil, expiresAt: .distantFuture))
            tokenStore = InMemoryTokenStore(signedIn)
            edgeStore = InMemoryEdgeTokenStore()
            let auth = AuthSession(store: tokenStore, transport: transport)
            let trashedElsewhere = arguments.firstIndex(of: "-ZimmerFixtureTrashedElsewhere")
                .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
            // `-ZimmerFixtureRefuse trash,follow_up`: those writes are refused, so a screen can
            // be seen putting back what it showed at the tap. `-ZimmerFixtureSlowWrites`: every
            // write takes six seconds, so a screen can be photographed ahead of the answer.
            let refuses = arguments.firstIndex(of: "-ZimmerFixtureRefuse")
                .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                .map { Set($0.split(separator: ",").map(String.init)) } ?? []
            let writeDelay: Duration? = arguments.contains("-ZimmerFixtureSlowWrites") ? .seconds(6) : nil
            // `-ZimmerFixtureVoiceTurnedUp`: the CarPlay drill's break-glass. The Live settings are
            // as voice calls left them on the call that broke (a cap of 180, eagerness low, a
            // threshold Semantic ignores, plus a gated Listening), and the first call holds on
            // Connecting… so the call screen stays up to be driven.
            let voiceTurnedUp = arguments.contains("-ZimmerFixtureVoiceTurnedUp")
            // `-ZimmerFixtureCarScript`: a call held on Connecting… for as long as a test needs it.
            let carScript = arguments.contains("-ZimmerFixtureCarScript")
            // `-ZimmerFixtureRelayOnly`: the sign-in may not act as you, so the Inference
            // page's writes are refused with the server's 403.
            connection = Connection(origins: signedIn?.origins, auth: auth, api: FakeZimmerAPI(live: arguments.contains("-ZimmerFixtureLive"),
                                                                                         longTranscript: arguments.contains("-ZimmerFixtureLongTranscript"),
                                                                                         relayOnly: arguments.contains("-ZimmerFixtureRelayOnly"), degraded: arguments.contains("-ZimmerFixtureDegraded"), trashedElsewhere: trashedElsewhere,
                                                                                         refuses: refuses, writeDelay: writeDelay,
                                                                                         liveSettings: voiceTurnedUp ? ["voice_max_output_tokens": .number(180), "voice_vad_eagerness": .string("low"), "voice_vad_threshold": .number(0.92), "voice_listening": .string("dynamic")] : [:],
                                                                                         liveSecretHold: voiceTurnedUp ? .seconds(120) : carScript ? .seconds(600) : nil,
                                                                                         web: origins.web), edge: nil)
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

    /// Point everything at the deployment a stored sign-in is for, keeping its edge login.
    /// For a connection built at launch from a Keychain read that failed, which therefore
    /// knows no deployment: the sign-in and the edge login it was made with are both current.
    func resume(_ origins: ServerOrigins) {
        guard !isFixture, connection.origins == nil else { return }
        connection = Self.makeConnection(origins: origins, transport: transport, tokenStore: tokenStore, edgeStore: edgeStore)
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let api = ZimmerHTTPClient(auth: auth, transport: transport, edge: edgeCredential, source: .app(version: version))
        return Connection(origins: origins, auth: auth, api: api, edge: edge)
    }
}
