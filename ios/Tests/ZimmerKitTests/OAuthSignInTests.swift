import XCTest
@testable import ZimmerKit

final class OAuthSignInTests: XCTestCase {
    private let pkce = PKCEPair(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
                                challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

    private func flow(_ origins: ServerOrigins = ServerOrigins(web: Fixtures.base)) -> OAuthSignIn {
        OAuthSignIn(origins: origins, pkce: pkce, state: "st")
    }

    func testTheAuthorizeURLAsksForTheBuiltInClientWithPKCEAndTheMcpResource() throws {
        let url = flow().authorizeURL
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.path, "/oauth/authorize")
        XCTAssertEqual(query["client_id"], "zimmer-ios")
        XCTAssertEqual(query["redirect_uri"], "com.tadasant.zimmer:/oauth/callback")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["code_challenge"], pkce.challenge)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "st")
        XCTAssertEqual(query["resource"], "https://zimmer.example.test/mcp")
    }

    func testTheCallbackYieldsTheCodeOnlyWhenItIsOurs() throws {
        let good = URL(string: "com.tadasant.zimmer:/oauth/callback?code=c1&state=st&iss=https://zimmer.example.test")!
        XCTAssertEqual(try flow().code(fromCallback: good), "c1")

        let wrongState = URL(string: "com.tadasant.zimmer:/oauth/callback?code=c1&state=other")!
        XCTAssertThrowsError(try flow().code(fromCallback: wrongState))

        let wrongIssuer = URL(string: "com.tadasant.zimmer:/oauth/callback?code=c1&state=st&iss=https://evil.test")!
        XCTAssertThrowsError(try flow().code(fromCallback: wrongIssuer))

        let denied = URL(string: "com.tadasant.zimmer:/oauth/callback?error=access_denied&state=st")!
        XCTAssertThrowsError(try flow().code(fromCallback: denied)) { error in
            XCTAssertEqual(error as? ZimmerError, .signIn("Sign-in was declined."))
        }

        let wrongScheme = URL(string: "https://zimmer.example.test/oauth/callback?code=c1&state=st")!
        XCTAssertThrowsError(try flow().code(fromCallback: wrongScheme))
    }

    func testCompletingASignInRedeemsTheCodeWithTheVerifierAndPersistsTheTokens() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.tokens(access: "zmr_oat_new", refresh: "zmr_ort_new") }])
        let store = InMemoryTokenStore()
        let auth = AuthSession(store: store, transport: transport)

        try await auth.complete(flow(), callback: URL(string: "com.tadasant.zimmer:/oauth/callback?code=c1&state=st")!)

        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(sent.url.path, "/oauth/token")
        let form = Fixtures.form(sent)
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], "c1")
        XCTAssertEqual(form["code_verifier"], pkce.verifier)
        XCTAssertEqual(form["client_id"], "zimmer-ios")
        XCTAssertEqual(form["redirect_uri"], "com.tadasant.zimmer:/oauth/callback")
        XCTAssertEqual(store.load()?.tokens.accessToken, "zmr_oat_new")
        XCTAssertEqual(store.load()?.origins.web, Fixtures.base)
        let token = try await auth.accessToken()
        XCTAssertEqual(token, "zmr_oat_new")
    }

    func testAnExpiringTokenIsRefreshedOnceEvenWhenAskedForTwiceAtOnce() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.tokens(access: "zmr_oat_fresh", refresh: "zmr_ort_fresh") }])
        let store = Fixtures.signedIn(expiresAt: Date().addingTimeInterval(10))
        let auth = AuthSession(store: store, transport: transport)

        async let first = auth.accessToken()
        async let second = auth.accessToken()
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["zmr_oat_fresh", "zmr_oat_fresh"])
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(Fixtures.form(transport.sent[0])["refresh_token"], "zmr_ort_old")
        XCTAssertEqual(store.load()?.tokens.refreshToken, "zmr_ort_fresh")
    }

    func testARevokedGrantSignsTheAppOut() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.json(400, ["error": "invalid_grant"]) }])
        let store = Fixtures.signedIn(expiresAt: Date())
        let auth = AuthSession(store: store, transport: transport)

        do {
            _ = try await auth.accessToken()
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .unauthorized)
        }
        XCTAssertNil(store.load())
        let signedIn = await auth.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testAnEdgeRefusalOfTheTokenCallIsItsOwnErrorAndKeepsTheSignIn() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.accessRefusal }])
        let store = Fixtures.signedIn(expiresAt: Date())
        let auth = AuthSession(store: store, transport: transport)

        do {
            _ = try await auth.accessToken()
            XCTFail("expected edgeRefused")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .edgeRefused)
        }
        XCTAssertNotNil(store.load(), "an edge refusal says nothing about Zimmer's grant")
    }

    func testSignOutRevokesTheRefreshTokenAndForgets() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.json(200, [:]) }])
        let store = Fixtures.signedIn()
        let auth = AuthSession(store: store, transport: transport)

        await auth.signOut()

        XCTAssertEqual(transport.sent.first?.url.path, "/oauth/revoke")
        XCTAssertEqual(Fixtures.form(transport.sent[0])["token"], "zmr_ort_old")
        XCTAssertNil(store.load())
    }

    func testOnASplitDeploymentAuthorizeIsOnTheWebHostAndTheTokenCallOnTheAppHostWithTheEdgeHeader() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.tokens() }])
        let edge = CloudflareAccessCredential(
            apiBaseURL: Fixtures.appHost,
            store: InMemoryEdgeTokenStore("edge-jwt"),
            presenter: { _ in throw ZimmerError.signIn("no sheet in this test") }
        )
        let auth = AuthSession(store: InMemoryTokenStore(), transport: transport, edge: edge)
        let split = flow(Fixtures.split)

        XCTAssertEqual(split.authorizeURL.host, "zimmer.example.test")
        XCTAssertEqual(split.resource, "https://zimmer.example.test/mcp", "the issuer's resource, not the app host's")
        try await auth.complete(split, callback: URL(string: "com.tadasant.zimmer:/oauth/callback?code=c1&state=st&iss=https://zimmer.example.test")!)

        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(sent.url.host, "zimmer-app.example.test")
        XCTAssertEqual(sent.headers["cf-access-token"], "edge-jwt")
        XCTAssertNil(sent.headers["Authorization"])
    }
}
