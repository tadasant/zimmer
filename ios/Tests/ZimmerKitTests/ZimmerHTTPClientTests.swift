import XCTest
@testable import ZimmerKit

final class ZimmerHTTPClientTests: XCTestCase {
    nonisolated(unsafe) private static let listBody: [String: Any] = [
        "sessions": [
            ["id": 1, "title": "Running", "status": "running", "updated_at": "2026-10-09T10:00:00Z"],
            ["id": 2, "title": "Asks", "status": "needs_input", "updated_at": "2026-10-09T09:00:00.123Z"],
            ["id": 3, "status": "some_future_status", "unknown_field": true],
        ],
        "pagination": ["page": 1],
    ]
    private let list = Fixtures.json(200, ZimmerHTTPClientTests.listBody)

    func testListingSendsTheBearerTokenAndTheFilterAndPutsNeedsInputFirst() async throws {
        let transport = ScriptedTransport([{ [list] _ in list }])
        let auth = AuthSession(store: Fixtures.signedIn(), transport: transport)
        let client = ZimmerHTTPClient(auth: auth, transport: transport)

        let sessions = try await client.sessions(.needsInput)

        let request = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer zmr_oat_old")
        XCTAssertEqual(request.url.path, "/api/v1/sessions")
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "status", value: "needs_input")))
        XCTAssertEqual(sessions.map(\.id), [2, 1, 3])
        XCTAssertEqual(sessions[2].status, .unknown("some_future_status"))
        XCTAssertEqual(sessions[2].displayTitle, "Session 3")
        XCTAssertNotNil(sessions[0].updatedAt, "fractional-second timestamps decode")
    }

    func testAZimmer401RefreshesOnceAndRetries() async throws {
        let transport = ScriptedTransport([
            { _ in Fixtures.json(401, ["error": "Unauthorized", "message": "Invalid or expired access token"]) },
            { _ in Fixtures.tokens(access: "zmr_oat_2") },
            { [list] _ in list },
        ])
        let auth = AuthSession(store: Fixtures.signedIn(), transport: transport)
        let client = ZimmerHTTPClient(auth: auth, transport: transport)

        _ = try await client.sessions(.active)

        XCTAssertEqual(transport.sent.map(\.url.path), ["/api/v1/sessions", "/oauth/token", "/api/v1/sessions"])
        XCTAssertEqual(transport.sent[2].headers["Authorization"], "Bearer zmr_oat_2")
    }

    func testA401ThatSurvivesAFreshTokenIsAnErrorAndKeepsTheSignIn() async throws {
        let refused = Fixtures.json(401, ["error": "Unauthorized", "message": "Invalid or missing API key"])
        let transport = ScriptedTransport([
            { _ in refused },
            { _ in Fixtures.tokens(access: "zmr_oat_2", refresh: "zmr_ort_2") },
            { _ in refused },
        ])
        let store = Fixtures.signedIn()
        let auth = AuthSession(store: store, transport: transport)
        let client = ZimmerHTTPClient(auth: auth, transport: transport)

        do {
            _ = try await client.sessions(.active)
            XCTFail("expected the endpoint's refusal")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .http(status: 401, message: "Invalid or missing API key"))
        }
        XCTAssertEqual(store.load()?.tokens.refreshToken, "zmr_ort_2", "the refreshed sign-in is kept")
        let signedIn = await auth.isSignedIn
        XCTAssertTrue(signedIn)
    }

    func testAnEdgeRefusalIsNotMistakenForASignOut() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.accessRefusal }])
        let store = Fixtures.signedIn()
        let auth = AuthSession(store: store, transport: transport)
        let client = ZimmerHTTPClient(auth: auth, transport: transport)

        do {
            _ = try await client.sessions(.active)
            XCTFail("expected edgeRefused")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .edgeRefused)
        }
        XCTAssertEqual(transport.sent.count, 1, "no token refresh for a refusal Zimmer never saw")
        XCTAssertNotNil(store.load())
    }

    func testTheEdgeCredentialDecoratesEveryRequestAndGetsOneChanceToRenew() async throws {
        let edge = RecordingEdge(canRenew: true)
        let transport = ScriptedTransport([
            { _ in Fixtures.accessRefusal },
            { [list] _ in list },
        ])
        let auth = AuthSession(store: Fixtures.signedIn(), transport: transport, edge: edge)
        let client = ZimmerHTTPClient(auth: auth, transport: transport, edge: edge)

        _ = try await client.sessions(.active)

        XCTAssertEqual(edge.renewalCount, 1)
        XCTAssertEqual(transport.sent.map { $0.headers["cf-access-token"] }, ["phone-token-0", "phone-token-1"])
    }

    func testEdgeRefusalDetection() {
        XCTAssertTrue(EdgeRefusal.isEdgeRefusal(Fixtures.accessRefusal))
        XCTAssertTrue(EdgeRefusal.isEdgeRefusal(Fixtures.accessRedirect))
        XCTAssertTrue(EdgeRefusal.isEdgeRefusal(HTTPResponse(statusCode: 403, headers: ["CF-Access-AUD": "x", "Content-Type": "text/html"])))
        XCTAssertFalse(EdgeRefusal.isEdgeRefusal(HTTPResponse(statusCode: 403, headers: ["Server": "cloudflare", "Content-Type": "text/html"])),
                       "server: cloudflare is on every response through the edge")
        XCTAssertFalse(EdgeRefusal.isEdgeRefusal(HTTPResponse(statusCode: 302, headers: ["location": "https://zimmer-app.example.test/x"])))
        XCTAssertFalse(EdgeRefusal.isEdgeRefusal(Fixtures.json(401, ["error": "Unauthorized"])))
        XCTAssertFalse(EdgeRefusal.isEdgeRefusal(Fixtures.json(401, ["error": "Unauthorized"], headers: ["server": "cloudflare", "content-type": "application/json"])),
                       "Zimmer's own JSON 401, proxied through Cloudflare, is still Zimmer's")
        XCTAssertFalse(EdgeRefusal.isEdgeRefusal(HTTPResponse(statusCode: 500, headers: ["cf-access-aud": "x"])))
    }

    func testATunnel404IsReportedAsAnAllowListBugNotRetried() async throws {
        let transport = ScriptedTransport([{ _ in HTTPResponse(statusCode: 404, headers: ["content-type": "text/plain; charset=utf-8"], body: Data("Not Found".utf8)) }])
        let client = ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport)

        do {
            _ = try await client.sessions(.active)
            XCTFail("expected edgeNotRouted")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .edgeNotRouted("/api/v1/sessions"))
        }
        XCTAssertFalse(EdgeRefusal.isEdgeNotRouted(Fixtures.json(404, ["error": "Not Found"], headers: ["content-type": "application/json", "x-request-id": "r"])))
    }

    func testAnErrorEnvelopeMessageReachesTheCaller() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.json(422, ["error": "Unprocessable Entity", "message": "prompt can't be blank"]) }])
        let auth = AuthSession(store: Fixtures.signedIn(), transport: transport)
        let client = ZimmerHTTPClient(auth: auth, transport: transport)

        do {
            _ = try await client.sessions(.active)
            XCTFail("expected http error")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .http(status: 422, message: "prompt can't be blank"))
        }
    }

    // A proxy that gives up on a slow answer replies with an HTML 504. The phone reached
    // Zimmer; it waited too long. "Couldn't reach" would send the reader to check their network.
    func testAGatewayTimeoutSaysItTimedOut() async throws {
        let html = HTTPResponse(statusCode: 504, headers: ["content-type": "text/html"], body: Data("<title>504 — Gateway Timeout</title>".utf8))
        let transport = ScriptedTransport([{ _ in html }])
        let auth = AuthSession(store: Fixtures.signedIn(), transport: transport)
        let client = ZimmerHTTPClient(auth: auth, transport: transport)

        do {
            _ = try await client.sessions(.active)
            XCTFail("expected timedOut")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .timedOut)
            XCTAssertEqual((error as? ZimmerError)?.userMessage, "Zimmer took too long to answer. Try again in a moment.")
        }
    }

    func testTheRequestsOwnTimeoutSaysItTimedOut() async throws {
        let transport = ScriptedTransport([{ _ in throw URLError(.timedOut) }])
        let auth = AuthSession(store: Fixtures.signedIn(), transport: transport)
        let client = ZimmerHTTPClient(auth: auth, transport: transport)

        do {
            _ = try await client.sessions(.active)
            XCTFail("expected timedOut")
        } catch {
            XCTAssertEqual(error as? ZimmerError, .timedOut)
        }
    }

    func testAnUnreachableServerStillSaysSo() async throws {
        let transport = ScriptedTransport([{ _ in throw URLError(.cannotConnectToHost) }])
        let auth = AuthSession(store: Fixtures.signedIn(), transport: transport)
        let client = ZimmerHTTPClient(auth: auth, transport: transport)

        do {
            _ = try await client.sessions(.active)
            XCTFail("expected transport")
        } catch {
            XCTAssertEqual((error as? ZimmerError)?.userMessage, "Couldn't reach Zimmer.")
        }
    }
}
