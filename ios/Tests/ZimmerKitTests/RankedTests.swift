import XCTest
@testable import ZimmerKit

/// Slice 2b: the server orders each board view, and the Ranked view's two writes.
final class RankedTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func query(_ request: HTTPRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testEachViewAsksTheServerForItsOrder() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["sessions": [["id": 1, "status": "running"]], "pagination": ["total_pages": 1]]) },
            { _ in Fixtures.json(200, ["sessions": [["id": 2, "status": "running"]], "pagination": ["total_pages": 1], "truncated": true]) },
        ])

        let touched = try await api.sessions(.active, board: .onBoard, view: .lastTouched)
        let ranked = try await api.sessions(.active, board: .onBoard, view: .ranked)

        XCTAssertEqual(query(transport.sent[0])["view"], "last_touched")
        XCTAssertEqual(query(transport.sent[0])["page"], "1", "a flat view pages as before")
        XCTAssertEqual(query(transport.sent[1])["view"], "ranked")
        XCTAssertNil(query(transport.sent[1])["page"], "the User view is one page")
        XCTAssertNil(query(transport.sent[1])["per_page"])
        XCTAssertTrue(touched.complete)
        XCTAssertFalse(ranked.complete, "`truncated` means the list says it was cut")
    }

    func testStartNowAndReorderHitTheirRoutes() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["session": ["id": 5, "status": "running"], "outcome": "started", "message": "Session 5's next turn is due now"]) },
            { _ in Fixtures.json(200, ["session": ["id": 5, "status": "waiting", "precedence": 40], "changes": [["id": 5, "precedence": 40]]]) },
            { _ in Fixtures.json(200, ["session": ["id": 5, "status": "waiting", "precedence": 60]]) },
        ])

        let message = try await api.startNow(5)
        let moved = try await api.reorder(5, above: 7, below: 8)
        _ = try await api.reorder(5, above: nil, below: 7)

        XCTAssertEqual(message, "Session 5's next turn is due now")
        XCTAssertEqual(moved.precedence, 40)
        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "POST /api/v1/sessions/5/start_now", "PATCH /api/v1/sessions/5/reorder_precedence", "PATCH /api/v1/sessions/5/reorder_precedence",
        ])
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[1].body ?? Data()) as? [String: Int])
        XCTAssertEqual(first, ["above_id": 7, "below_id": 8])
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[2].body ?? Data()) as? [String: Int])
        XCTAssertEqual(top, ["below_id": 7], "dropped at the top: no row above")
    }

    func testTheFixtureStartsOnlyAWaitingSessionAndPlacesADropBetweenItsNeighbours() async throws {
        let fake = FakeZimmerAPI()
        await XCTAssertThrowsAsync(try await fake.startNow(1042), "a running session has nothing to bring forward")
        _ = try await fake.startNow(1031)
        let moved = try await fake.reorder(1027, above: 1031, below: 1042)
        XCTAssertEqual(moved.precedence, 40, "midway between 50 and 30")
        await XCTAssertThrowsAsync(try await fake.reorder(1027, above: 1027, below: nil), "not next to itself")
    }
}
