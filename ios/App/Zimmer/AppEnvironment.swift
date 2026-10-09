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

    let configuration = AppConfiguration()
    let auth: AuthSession
    let api: ZimmerAPI
    /// True when a `#if DEBUG` launch argument swapped in the in-memory fake.
    let isFixture: Bool

    private init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ZimmerFixture") {
            // A screen with no server and no sign-in, for the UI test and screenshots: an
            // agent cannot complete a Google sign-in. `-ZimmerFixtureSignedOut` shows the
            // sign-in screen instead of the list.
            let base = AppConfiguration.buildDefaultBaseURL ?? URL(string: "https://fixture.invalid")!
            let signedIn = arguments.contains("-ZimmerFixtureSignedOut")
                ? nil
                : StoredSignIn(baseURL: base, tokens: OAuthTokens(accessToken: "fixture", refreshToken: nil, expiresAt: .distantFuture))
            auth = AuthSession(store: InMemoryTokenStore(signedIn), transport: URLSessionTransport())
            api = FakeZimmerAPI()
            isFixture = true
            return
        }
        #endif

        let transport = URLSessionTransport()
        // The seam for whatever the deployment's network edge asks of a phone. Nothing yet:
        // see EdgeCredential, and ios/README.md "Reaching a server behind an access proxy".
        let edge: EdgeCredential = NoEdgeCredential()
        auth = AuthSession(store: KeychainTokenStore(), transport: transport, edge: edge)
        api = ZimmerHTTPClient(auth: auth, transport: transport, edge: edge)
        isFixture = false
    }
}
