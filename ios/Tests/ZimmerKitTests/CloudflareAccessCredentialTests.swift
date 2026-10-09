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
            return URL(string: "com.tadasant.zimmer:/access/callback?state=\(state)&cf_access_token=\(token)")!
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

    func testACallbackForAnotherStateIsRefused() throws {
        let callback = URL(string: "com.tadasant.zimmer:/access/callback?state=other&cf_access_token=\(goodJWT)")!
        XCTAssertThrowsError(try CloudflareAccessCredential.token(fromCallback: callback, state: "mine"))
        let wrongPath = URL(string: "com.tadasant.zimmer:/oauth/callback?state=mine&cf_access_token=\(goodJWT)")!
        XCTAssertThrowsError(try CloudflareAccessCredential.token(fromCallback: wrongPath, state: "mine"))
        let noToken = URL(string: "com.tadasant.zimmer:/access/callback?state=mine")!
        XCTAssertThrowsError(try CloudflareAccessCredential.token(fromCallback: noToken, state: "mine"))
    }

    func testRefreshIsDueWithinTwentyFourHoursOfExpiry() async {
        let fresh = credential(store: InMemoryEdgeTokenStore(goodJWT), presenter: { _ in throw URLError(.cancelled) })
        let expiring = credential(store: InMemoryEdgeTokenStore(Fixtures.jwt(exp: Date().addingTimeInterval(3_600))), presenter: { _ in throw URLError(.cancelled) })
        let missing = credential(store: InMemoryEdgeTokenStore(), presenter: { _ in throw URLError(.cancelled) })

        let results = await [fresh.needsLogin(), expiring.needsLogin(), missing.needsLogin()]
        XCTAssertEqual(results, [false, true, true])
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
