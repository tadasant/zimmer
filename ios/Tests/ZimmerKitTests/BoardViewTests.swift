import XCTest
@testable import ZimmerKit

/// Slice 2: the web UI's board views, bulk trash, refresh all, the hierarchy and the transcript.
final class BoardViewTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private let now = Date(timeIntervalSince1970: 1_791_700_000)
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private var rows: [SessionSummary] {
        [
            SessionSummary(id: 1, status: .running, createdAt: ago(10), priorityClass: "spot", precedence: 5),
            SessionSummary(id: 2, status: .needsInput, createdAt: ago(50), priorityClass: "priority", precedence: 0, lastUserActivityAt: ago(1)),
            SessionSummary(id: 3, status: .waiting, createdAt: ago(30), priorityClass: "spot", precedence: 9),
            SessionSummary(id: 4, status: .failed, createdAt: ago(40), priorityClass: "spot", precedence: 5),
            SessionSummary(id: 5, status: .waiting, createdAt: ago(5), priorityClass: "priority", precedence: 3),
        ]
    }

    func testYourBoardIsTheUserViewsOrder() {
        // Priority first; then precedence descending; then oldest first (4 is older than 1).
        let order = BoardView.yourBoard.sections(rows).flatMap(\.sessions).map(\.id)
        XCTAssertEqual(order, [5, 2, 3, 4, 1])
        XCTAssertEqual(BoardView.yourBoard.sections(rows).count, 1, "one list, as the web UI draws it")
    }

    func testRankedSplitsTheSameOrderIntoPriorityAndTheSpotQueue() {
        let sections = BoardView.ranked.sections(rows)
        XCTAssertEqual(sections.map(\.title), ["Priority", "Spot queue"])
        XCTAssertEqual(sections.map { $0.sessions.map(\.id) }, [[5, 2], [3, 4, 1]])
    }

    func testLastTouchedFallsBackToCreatedAndCreatedIsNewestFirst() {
        XCTAssertEqual(BoardView.lastTouched.sections(rows)[0].sessions.map(\.id), [2, 5, 1, 3, 4],
                       "2 was touched a minute ago; the rest sort by when they were created")
        XCTAssertEqual(BoardView.created.sections(rows)[0].sessions.map(\.id), [5, 1, 3, 4, 2])
    }

    func testLastUserActivityIsReadLeniently() throws {
        let json: [String: Any] = ["sessions": [
            ["id": 1, "status": "running", "metadata": ["last_user_activity_at": "2026-10-10T12:00:00Z"]],
            ["id": 2, "status": "running", "created_at": "2026-10-09T12:00:00Z", "metadata": ["last_user_activity_at": "not a time"]],
        ]]
        let rows = try ZimmerJSON.decoder.decode(SessionListResponse.self, from: JSONSerialization.data(withJSONObject: json)).sessions
        XCTAssertEqual(rows[0].lastTouchedAt, ZimmerJSON.parseDate("2026-10-10T12:00:00Z"))
        XCTAssertEqual(rows[1].lastTouchedAt, ZimmerJSON.parseDate("2026-10-09T12:00:00Z"), "a value that is not a time falls back to created")
    }

    func testTheListReadsEveryPageUpToTheBoardsCap() async throws {
        func page(_ ids: [Int], pages: Int) -> ScriptedTransport.Handler {
            { _ in Fixtures.json(200, ["sessions": ids.map { ["id": $0, "status": "running"] }, "pagination": ["page": 1, "total_pages": pages]]) }
        }
        let (api, transport) = client([page([1, 2], pages: 3), page([3], pages: 3), page([3, 4], pages: 3)])

        let rows = try await api.sessions(.active, board: .onBoard)

        XCTAssertEqual(transport.sent.count, 3)
        XCTAssertEqual(transport.sent.map { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value }, ["1", "2", "3"])
        XCTAssertEqual(Set(rows.map(\.id)), [1, 2, 3, 4], "a row that moved between pages is shown once")
    }

    func testBulkTrashRefreshAllAndTheTranscript() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["archived_count": 1, "errors": [["id": 7, "message": "A turn is in flight"]]]) },
            { _ in Fixtures.json(200, ["message": "Refresh complete", "refreshed": 4, "restarted": 1, "continued": 0, "errors": 0]) },
            { _ in Fixtures.json(200, ["message": "No non-archived sessions to refresh", "refreshed": 0, "restarted": 0, "continued": 0, "errors": 0]) },
            { _ in Fixtures.json(200, ["transcript_text": "User: hi\n\nAssistant: hello"]) },
        ])

        let bulk = try await api.bulkArchive([6, 7])
        let refreshed = try await api.refreshAll()
        let nothing = try await api.refreshAll()
        let text = try await api.transcriptText(6)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "POST /api/v1/sessions/bulk_archive", "POST /api/v1/sessions/refresh_all",
            "POST /api/v1/sessions/refresh_all", "GET /api/v1/sessions/6/transcript",
        ])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[0].body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["session_ids"] as? [Int], [6, 7])
        XCTAssertEqual(bulk.archivedCount, 1)
        XCTAssertEqual(bulk.errors.first?.message, "A turn is in flight")
        XCTAssertEqual(refreshed, "Refreshed 4, restarted 1, continued 0")
        XCTAssertEqual(nothing, "No non-archived sessions to refresh")
        XCTAssertEqual(text, "User: hi\n\nAssistant: hello")
    }

    func testTheHierarchyIsDecodedAndABrokenOneDoesNotBreakThePage() async throws {
        let (api, _) = client([
            { _ in Fixtures.json(200, [
                "session": ["id": 2, "status": "running"],
                "session_hierarchy": ["origin_session_id": 1, "truncated": false, "nodes": [
                    ["id": 1, "title": "Router", "agent_root": "zimmer-orchestrator", "status": "needs_input", "depth": 0, "current": false],
                    ["id": 2, "title": nil as String? as Any, "status": "running", "depth": 1, "current": true],
                ]],
            ]) },
            { _ in Fixtures.json(200, ["session": ["id": 3, "status": "running"], "session_hierarchy": "not an object"]) },
        ])

        let detail = try await api.session(2)
        let hierarchy = try XCTUnwrap(detail.hierarchy)
        XCTAssertEqual(hierarchy.nodes.map(\.depth), [0, 1])
        XCTAssertEqual(hierarchy.nodes[1].displayTitle, "Session 2")
        XCTAssertTrue(hierarchy.nodes[1].current)
        XCTAssertTrue(hierarchy.isWorthShowing)

        let other = try await api.session(3)
        XCTAssertNil(other.hierarchy)
    }

    func testTheFixtureBulkTrashesWhatTheServerWouldAndReportsTheRest() async throws {
        let fake = FakeZimmerAPI()
        let result = try await fake.bulkArchive([1035, 1042])
        XCTAssertEqual(result.archivedCount, 1)
        XCTAssertEqual(result.errors.map(\.id), [1042], "a session mid-turn is refused, the rest go")
    }
}
