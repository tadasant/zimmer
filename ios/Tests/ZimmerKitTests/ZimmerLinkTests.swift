import XCTest
@testable import ZimmerKit

/// A link to one of this deployment's pages is the app's screen for it; anything else is a link.
final class ZimmerLinkTests: XCTestCase {
    private let origins = ServerOrigins(web: URL(string: "https://zimmer.example.com")!,
                                        api: URL(string: "https://zimmer-app.example.com")!)

    private func link(_ raw: String) -> ZimmerLink? {
        ZimmerLink(url: URL(string: raw)!, origins: origins)
    }

    func testASessionLinkIsItsScreenHoweverItIsWritten() {
        XCTAssertEqual(link("https://zimmer.example.com/sessions/25555"), .session(25555))
        XCTAssertEqual(link("https://zimmer.example.com/sessions/25555/"), .session(25555))
        XCTAssertEqual(link("https://ZIMMER.example.com/sessions/25555"), .session(25555), "hosts are case-insensitive")
        XCTAssertEqual(link("https://zimmer.example.com:443/sessions/25555"), .session(25555))
        XCTAssertEqual(link("https://zimmer.example.com/sessions/25555?tab=notes#message-4"), .session(25555))
        XCTAssertEqual(link("https://zimmer-app.example.com/sessions/7"), .session(7), "the app host is this deployment too")
    }

    func testASlugIsResolvedLaterAndOnlyAValidSlugCounts() {
        XCTAssertEqual(link("https://zimmer.example.com/sessions/fix-ios-links"), .sessionSlug("fix-ios-links"))
        XCTAssertEqual(link("https://zimmer.example.com/sessions/new"), .newSession)
        XCTAssertNil(link("https://zimmer.example.com/sessions/Fix_Links"), "not a slug the server allows")
        XCTAssertNil(link("https://zimmer.example.com/sessions/0"), "digits alone are an id, and no session is 0")
    }

    func testEveryPageWithAScreenHereIsRecognised() {
        XCTAssertEqual(link("https://zimmer.example.com"), .board)
        XCTAssertEqual(link("https://zimmer.example.com/"), .board)
        XCTAssertEqual(link("https://zimmer.example.com/?view=ranked"), .board)
        XCTAssertEqual(link("https://zimmer.example.com/sessions"), .board)
        XCTAssertEqual(link("https://zimmer.example.com/notifications"), .inbox)
        XCTAssertEqual(link("https://zimmer.example.com/triggers"), .triggers)
        XCTAssertEqual(link("https://zimmer.example.com/triggers/12"), .trigger(12))
        XCTAssertEqual(link("https://zimmer.example.com/costs"), .costs(.fleet))
        XCTAssertEqual(link("https://zimmer.example.com/costs?agent_root=zimmer"), .costs(.agentRoot("zimmer")))
        XCTAssertEqual(link("https://zimmer.example.com/costs?session_id=9"), .costs(.session(9)))
        XCTAssertEqual(link("https://zimmer.example.com/health"), .health)
        XCTAssertEqual(link("https://zimmer.example.com/clis"), .clis)
        XCTAssertEqual(link("https://zimmer.example.com/settings"), .settings)
        XCTAssertEqual(link("https://zimmer.example.com/settings/api_keys"), .apiKeys)
        XCTAssertEqual(link("https://zimmer.example.com/live"), .live)
    }

    func testAPageWithNoScreenHereOpensAsALink() {
        XCTAssertNil(link("https://zimmer.example.com/sessions/25555/edit"))
        XCTAssertNil(link("https://zimmer.example.com/triggers/12/edit"))
        XCTAssertNil(link("https://zimmer.example.com/triggers/new"))
        XCTAssertNil(link("https://zimmer.example.com/outcomes"))
        XCTAssertNil(link("https://zimmer.example.com/connectors"))
        XCTAssertNil(link("https://zimmer.example.com/settings/models"))
    }

    func testAnotherHostOrSchemeIsNeverThisZimmer() {
        XCTAssertNil(link("https://github.com/tadasant/zimmer/pull/1"))
        XCTAssertNil(link("https://zimmer.example.com.evil.test/sessions/1"))
        XCTAssertNil(link("https://evil.test/sessions/1?host=zimmer.example.com"))
        XCTAssertNil(link("https://zimmer.example.com:8443/sessions/1"), "another port is another origin")
        XCTAssertNil(link("http://zimmer.example.com/sessions/1"), "the app only ever signs in over https")
        XCTAssertNil(link("mailto:someone@zimmer.example.com"))
    }

    func testOneOriginServesBoth() {
        let single = ServerOrigins(web: URL(string: "https://zimmer.example.com")!)
        XCTAssertEqual(ZimmerLink(url: URL(string: "https://zimmer.example.com/sessions/3")!, origins: single), .session(3))
        XCTAssertNil(ZimmerLink(url: URL(string: "https://zimmer-app.example.com/sessions/3")!, origins: single))
    }

    func testASlugIsLookedUpWhereAnIdIs() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.json(200, ["session": ["id": 41, "slug": "fix-ios-links", "status": "running"]]) }])
        let api = ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport)
        let detail = try await api.session(slug: "fix-ios-links")
        XCTAssertEqual(detail.session.id, 41)
        XCTAssertEqual(transport.requests.first?.url.path, "/api/v1/sessions/fix-ios-links")
    }
}
