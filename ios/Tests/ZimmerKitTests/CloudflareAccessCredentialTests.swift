import XCTest
@testable import ZimmerKit

final class CloudflareAccessCredentialTests: XCTestCase {
    private let goodJWT = Fixtures.jwt(exp: Date().addingTimeInterval(30 * 86_400))

    private func credential(store: EdgeTokenStore, presenter: @escaping CloudflareAccessCredential.Presenter) -> CloudflareAccessCredential {
        CloudflareAccessCredential(apiBaseURL: Fixtures.appHost, store: store, presenter: presenter)
    }

    /// A presenter standing in for the sign-in sheet: answers with the callback Rails would
    /// redirect to, echoing the state from the handoff URL it was opened on.
    private func handoffPresenter(token: String, opened: OpenedURLs) -> CloudflareAccessCredential.Presenter {
        { url in
            opened.append(url)
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "com.tadasant.zimmer:/access/callback?state=\(state)#cf_access_token=\(token)")!
        }
    }

    func testTheHandoffOpensTheAppHostAndStoresTheTokenAfterCheckingState() async throws {
        let store = InMemoryEdgeTokenStore()
        let opened = OpenedURLs()
        let edge = credential(store: store, presenter: handoffPresenter(token: goodJWT, opened: opened))

        try await edge.login()

        let url = try XCTUnwrap(opened.urls.first)
        XCTAssertEqual(url.host, "zimmer-app.example.test")
        XCTAssertEqual(url.path, "/native/access-handoff")
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        XCTAssertGreaterThanOrEqual(state.count, 32)
        XCTAssertEqual(store.load(), goodJWT)
        let headers = await edge.headers()
        XCTAssertEqual(headers, ["cf-access-token": goodJWT])
    }

    func testTheTokenIsReadFromTheFragmentAndTheStateFromTheQuery() throws {
        // The exact shape NativeAccessHandoffsController redirects to.
        let callback = URL(string: "com.tadasant.zimmer:/access/callback?state=mine#cf_access_token=\(goodJWT)")!
        XCTAssertEqual(try CloudflareAccessCredential.token(fromCallback: callback, state: "mine"), goodJWT)

        let otherState = URL(string: "com.tadasant.zimmer:/access/callback?state=other#cf_access_token=\(goodJWT)")!
        XCTAssertThrowsError(try CloudflareAccessCredential.token(fromCallback: otherState, state: "mine"))
        let tokenInQuery = URL(string: "com.tadasant.zimmer:/access/callback?state=mine&cf_access_token=\(goodJWT)")!
        XCTAssertThrowsError(try CloudflareAccessCredential.token(fromCallback: tokenInQuery, state: "mine"),
                             "the contract puts the token in the fragment; a query token is not accepted")
        let wrongPath = URL(string: "com.tadasant.zimmer:/oauth/callback?state=mine#cf_access_token=\(goodJWT)")!
        XCTAssertThrowsError(try CloudflareAccessCredential.token(fromCallback: wrongPath, state: "mine"))
        let noToken = URL(string: "com.tadasant.zimmer:/access/callback?state=mine")!
        XCTAssertThrowsError(try CloudflareAccessCredential.token(fromCallback: noToken, state: "mine"))
    }

    func testNoURLTheAppBuildsHasADoubleSlashInItsPath() {
        // The app host's tunnel answers 404 to any path containing `//`.
        let origins = [URL(string: "https://zimmer-app.example.test")!, URL(string: "https://zimmer-app.example.test/")!]
        for base in origins {
            let flow = OAuthSignIn(origins: ServerOrigins(web: base, api: base))
            let urls = [
                CloudflareAccessCredential.handoffURL(apiBaseURL: base, state: "s"),
                flow.authorizeURL,
                flow.tokenRequest(code: "c").url,
                OAuthSignIn.refreshRequest(baseURL: base, refreshToken: "r").url,
                OAuthSignIn.revokeRequest(baseURL: base, token: "t").url,
                HTTPEndpoint(method: "GET", path: "/api/v1/sessions").url(relativeTo: base)!,
            ]
            for url in urls {
                XCTAssertFalse(url.path.contains("//"), "\(url.absoluteString) has a // in its path")
            }
        }
    }

    /// A week ahead, not a day: the phone renews only when its own screen is in front, and one used
    /// from the car for days at a time let a day's window pass unseen (2026-11-26).
    func testRefreshIsDueWithinAWeekOfExpiry() async {
        let refuse: CloudflareAccessCredential.Presenter = { _ in throw URLError(.cancelled) }
        let fresh = credential(store: InMemoryEdgeTokenStore(goodJWT), presenter: refuse)
        let eightDays = credential(store: InMemoryEdgeTokenStore(Fixtures.jwt(exp: Date().addingTimeInterval(8 * 86_400))), presenter: refuse)
        let sixDays = credential(store: InMemoryEdgeTokenStore(Fixtures.jwt(exp: Date().addingTimeInterval(6 * 86_400))), presenter: refuse)
        let expiring = credential(store: InMemoryEdgeTokenStore(Fixtures.jwt(exp: Date().addingTimeInterval(3_600))), presenter: refuse)
        let lapsed = credential(store: InMemoryEdgeTokenStore(Fixtures.jwt(exp: Date().addingTimeInterval(-60))), presenter: refuse)
        let missing = credential(store: InMemoryEdgeTokenStore(), presenter: refuse)

        let results = await [fresh.needsLogin(), eightDays.needsLogin(), sixDays.needsLogin(), expiring.needsLogin(),
                             lapsed.needsLogin(), missing.needsLogin()]
        XCTAssertEqual(results, [false, false, true, true, true, true])
        XCTAssertEqual(CloudflareAccessCredential.expiry(of: goodJWT).map { Int($0.timeIntervalSinceNow / 86_400) }, 29)
        XCTAssertNil(CloudflareAccessCredential.expiry(of: "not-a-jwt"))
    }

    func testAnAccessRefusalOfAnAPICallRunsTheHandoffAndRetriesOnce() async throws {
        let store = InMemoryEdgeTokenStore(Fixtures.jwt(exp: Date().addingTimeInterval(-60)))
        let opened = OpenedURLs()
        let edge = credential(store: store, presenter: handoffPresenter(token: goodJWT, opened: opened))
        let list = Fixtures.json(200, ["sessions": []])
        let transport = ScriptedTransport([{ _ in Fixtures.accessRedirect }, { [list] _ in list }])
        let auth = AuthSession(store: Fixtures.signedIn(origins: Fixtures.split), transport: transport, edge: edge)
        let client = ZimmerHTTPClient(auth: auth, transport: transport, edge: edge)

        _ = try await client.sessions(.needsInput)

        XCTAssertEqual(opened.urls.count, 1)
        XCTAssertEqual(transport.sent.map(\.url.host), ["zimmer-app.example.test", "zimmer-app.example.test"])
        XCTAssertEqual(transport.sent[1].headers["cf-access-token"], goodJWT)
        XCTAssertEqual(transport.sent[1].headers["Authorization"], "Bearer zmr_oat_old", "the edge's token never displaces Zimmer's")
    }

    func testAnEdgeThatStillRefusesAfterTheHandoffIsEdgeRefusedAndKeepsTheZimmerSignIn() async throws {
        let opened = OpenedURLs()
        let edge = credential(store: InMemoryEdgeTokenStore(goodJWT), presenter: handoffPresenter(token: goodJWT, opened: opened))
        let transport = ScriptedTransport([{ _ in Fixtures.accessRefusal }, { _ in Fixtures.accessRefusal }])
        let store = Fixtures.signedIn(origins: Fixtures.split)
        let client = ZimmerHTTPClient(auth: AuthSession(store: store, transport: transport, edge: edge), transport: transport, edge: edge)

        do {
            _ = try await client.sessions(.active)
            XCTFail("expected edgeRefused")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .edgeRefused)
        }
        XCTAssertEqual(opened.urls.count, 1, "one handoff, one retry, then stop")
        XCTAssertNotNil(store.load())
    }

    /// The 2026-11-26 CarPlay incident, end to end in ZimmerKit: the edge credential has lapsed, the
    /// car's tap asks Zimmer for its conversation, Access redirects to its login, and the sign-in sheet
    /// cannot open (the app's presenter refuses with no phone screen in front). The tap fails as the
    /// edge refusing the phone, which the car shows as a block to sign in on the phone rather than
    /// retrying the same refusal until it says Live Mode is unavailable.
    func testALapsedEdgeCredentialFromTheCarIsABlockToSignInOnThePhone() async throws {
        let opened = OpenedURLs()
        let noScreen: CloudflareAccessCredential.Presenter = { url in
            opened.append(url)
            throw ZimmerError.signIn("The sign-in sheet needs Zimmer open on the phone.")
        }
        let edge = credential(store: InMemoryEdgeTokenStore(Fixtures.jwt(exp: Date().addingTimeInterval(-60))), presenter: noScreen)
        let transport = ScriptedTransport([{ _ in Fixtures.accessRedirect }])
        let store = Fixtures.signedIn(origins: Fixtures.split)
        let client = ZimmerHTTPClient(auth: AuthSession(store: store, transport: transport, edge: edge), transport: transport, edge: edge)

        var thrown: Error?
        do {
            _ = try await client.live(from: .carplay).conversation(for: .startNew)
        } catch {
            thrown = error
        }

        let error = try XCTUnwrap(thrown, "the tap cannot have a conversation")
        XCTAssertEqual(error as? ZimmerError, .edgeRefused)
        XCTAssertEqual(transport.sent.count, 1, "nothing more is sent once the sheet cannot open")
        XCTAssertEqual(opened.urls.count, 1, "the renewal was tried, once")
        XCTAssertNotNil(store.load(), "Zimmer's own sign-in is kept")

        let block = try XCTUnwrap(LiveBlock(error: error))
        XCTAssertEqual(block, .signInOnPhone)
        var retry = LiveRetry()
        retry.asked()
        retry.gaveUp(blockedBy: block)
        XCTAssertNil(retry.failed(), "no retry is spent on a refusal every retry would meet")
        XCTAssertEqual(retry.tiles(callIsActive: false, conversationOpen: true), [.blocked(.signInOnPhone)])
        XCTAssertEqual(retry.tile(callIsActive: false).titleVariants.first, "Sign in on your phone")
    }

    /// The reminder to open the phone comes an hour into the renewal window, the same moment however
    /// often it is asked, and not at all once that moment has passed or with nothing to renew.
    func testTheRenewalReminderComesAnHourIntoTheWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = now.addingTimeInterval(30 * 86_400)
        let date = EdgeRenewalReminder.fireDate(expiry: expiry, now: now)
        XCTAssertEqual(date, expiry.addingTimeInterval(-7 * 86_400 + 3_600))
        XCTAssertEqual(EdgeRenewalReminder.fireDate(expiry: expiry, now: now.addingTimeInterval(86_400)), date, "the same moment, asked later")
        XCTAssertNil(EdgeRenewalReminder.fireDate(expiry: expiry, now: expiry.addingTimeInterval(-6 * 86_400)), "inside the window, past the moment")
        XCTAssertNil(EdgeRenewalReminder.fireDate(expiry: nil, now: now))
    }

    func testTheRedirectGuardStopsAtAccessLoginPagesOnly() {
        XCTAssertFalse(AccessRedirectGuard.shouldFollow(URL(string: "https://tadasant.cloudflareaccess.com/cdn-cgi/access/login/x")))
        XCTAssertTrue(AccessRedirectGuard.shouldFollow(URL(string: "https://zimmer-app.example.test/api/v1/sessions")))
    }
}

final class OpenedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func append(_ url: URL) { lock.withLock { stored.append(url) } }
    var urls: [URL] { lock.withLock { stored } }
}
