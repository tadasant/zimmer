import XCTest
@testable import ZimmerKit

/// What the board's rows and the session page read that the web draws and the app did not:
/// genesis, precedence and the compaction window off `session_json`; a session's cost off
/// `GET /api/v1/costs?session_id=`; and the new-session form's fields on `POST /api/v1/sessions`.
final class BoardReadParityTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
    }

    private func query(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - The row's facts, as `ApiSessionSerialization#session_json` writes them

    func testARowReadsItsGenesisPrecedenceAndCompactionWindow() throws {
        let json: [String: Any] = [
            "id": 1031, "status": "waiting", "genesis": "schedule", "scheduling_class": NSNull(), "priority_class": "spot",
            "precedence": 50, "auto_compact_window": 400_000, "heartbeat_enabled": true, "heartbeat_interval_seconds": 300,
            "metadata": ["agent_root_key": "zimmer"],
        ]
        let session = try ZimmerJSON.decoder.decode(SessionSummary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(session.genesis, "schedule")
        XCTAssertEqual(session.precedence, 50)
        XCTAssertEqual(session.autoCompactWindow, 400_000)
        XCTAssertEqual(session.agentRoot, "zimmer")
        XCTAssertEqual(session.heartbeatEnabled, true)
        XCTAssertTrue(session.schedulingClassDerived, "no class of its own: the genesis decides")
        XCTAssertFalse(session.isPriority)
    }

    // MARK: - The new-session form

    func testTheFormsFieldsRideOnTheCreate() async throws {
        let (api, transport) = client([{ _ in Fixtures.json(201, ["session": ["id": 78, "status": "waiting"]]) }])
        let request = NewSessionRequest(
            agentRoot: "zimmer", prompt: "", precedence: 70, autoCompactWindow: 400_000, cloneOnly: true, idempotencyKey: "k-2"
        )
        _ = try await api.createSession(request)
        let sent = try body(try XCTUnwrap(transport.sent.first))
        XCTAssertEqual(sent["clone_only"] as? Bool, true)
        XCTAssertEqual(sent["prompt"] as? String, "", "the server refuses a prompt beside clone_only")
        XCTAssertEqual(sent["precedence"] as? Int, 70)
        XCTAssertEqual(sent["auto_compact_window"] as? Int, 400_000)
    }

    func testFieldsLeftBlankAreNotSent() throws {
        let sent = NewSessionRequest(agentRoot: "zimmer", prompt: "x").body
        XCTAssertNil(sent["precedence"], "blank is the server's 0, as the web form leaves it")
        XCTAssertNil(sent["auto_compact_window"], "blank is the column default")
        XCTAssertNil(sent["clone_only"])
        XCTAssertNil(sent["scheduling_class"], "none sent: the server classes the app's create priority")
    }

    func testTheFixtureCreatesAsTheServerDoesForTheApp() async throws {
        let fake = FakeZimmerAPI()
        let session = try await fake.createSession(NewSessionRequest(agentRoot: "zimmer", prompt: "", precedence: 70, autoCompactWindow: 400_000, cloneOnly: true))
        XCTAssertEqual(session.status, .needsInput, "a clone set up with no first turn waits on a person")
        XCTAssertEqual(session.precedence, 70)
        XCTAssertEqual(session.autoCompactWindow, 400_000)
        XCTAssertEqual(session.genesis, "api")
        XCTAssertEqual(session.priorityClass, "priority", "no class sent: the app's create is written priority, as on the server")
        XCTAssertEqual(session.schedulingClass, "priority")
        await XCTAssertThrowsAsync(try await fake.createSession(NewSessionRequest(agentRoot: "zimmer", prompt: "Go", cloneOnly: true)), "a prompt beside clone_only is refused")
        let chosen = try await fake.createSession(NewSessionRequest(agentRoot: "zimmer", prompt: "Go", schedulingClass: "spot"))
        XCTAssertEqual(chosen.priorityClass, "spot", "a class the app sent stands")
        XCTAssertEqual(chosen.status, .waiting)
    }

    // MARK: - A session's cost

    func testTheLifetimeWindowCoversTheSessionFromItsFirstDay() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let created = now.addingTimeInterval(-500 * 86_400)
        let window = CostWindow.lifetime(from: created, now: now)
        let sent = window.query(calendar: Calendar(identifier: .gregorian))
        let from = ZimmerJSON.parseDate(sent["from"] ?? "")
        let to = ZimmerJSON.parseDate(sent["to"] ?? "")
        XCTAssertNotNil(from)
        XCTAssertLessThanOrEqual(try XCTUnwrap(from), created, "the first day is in, however long ago: the server caps `days`, not explicit bounds")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(to), now, "and today")
        XCTAssertEqual(CostWindow.lifetime(from: nil, now: now), .days(CostWindow.maxDays), "with no creation date, the year the server allows")
    }

    func testASessionsCostIsTheNarrowedTotal() async throws {
        let (api, transport) = client([{ _ in
            Fixtures.json(200, [
                "window": ["from": "2026-01-01T00:00:00Z", "to": "2026-10-15T00:00:00Z"],
                "scope": ["agent_root": NSNull(), "session_id": 1038],
                "totals": ["cost_usd": 17.02, "session_cost_usd": 17.02, "adhoc_cost_usd": 0, "total_tokens": 880_120],
                "by_day": [], "by_agent_root": [], "by_model": [], "top_sessions": [],
            ])
        }])
        let cost = try await api.sessionCost(1038, createdAt: Date().addingTimeInterval(-3600))
        XCTAssertEqual(cost, 17.02, accuracy: 0.0001)
        let sent = try XCTUnwrap(transport.sent.first)
        XCTAssertEqual(sent.url.path, "/api/v1/costs")
        XCTAssertEqual(query(sent)["session_id"], "1038")
        XCTAssertNotNil(query(sent)["from"])
    }

    func testTheFixtureKnowsWhatItsSessionsSpent() async throws {
        let fake = FakeZimmerAPI()
        let spent = try await fake.sessionCost(1038, createdAt: nil)
        XCTAssertEqual(spent, 17.02, accuracy: 0.0001)
        let nothing = try await fake.sessionCost(1031, createdAt: nil)
        XCTAssertEqual(nothing, 0, "a session the ledger has nothing for reads zero, which the page draws as nothing")
    }
}
