import XCTest
@testable import ZimmerKit

/// Your board's rows: each session's agent root and "where things stand", from `include=board_row`.
final class BoardRowTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    func testYourBoardAsksForTheRowsAndAttachesThem() async throws {
        let (api, transport) = client([{ _ in
            Fixtures.json(200, [
                "sessions": [["id": 7, "status": "needs_input"], ["id": 8, "status": "needs_input"]],
                "pagination": ["total_pages": 1],
                "board_rows": [
                    "7": ["agent_root": "zimmer", "status_summary": ["summary": "The PR is [open](https://x/pull/1).", "messages_since_generated": 2, "generating": false]],
                    "8": ["agent_root": NSNull(), "status_summary": NSNull()],
                ],
            ])
        }])
        let result = try await api.sessions(.default, board: .onBoard, view: .yourBoard)
        let query = URLComponents(url: try XCTUnwrap(transport.sent.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "include" }?.value, "board_row")

        let first = try XCTUnwrap(result.sessions.first { $0.id == 7 })
        XCTAssertEqual(first.agentRoot, "zimmer")
        XCTAssertEqual(first.boardRow?.statusSummary?.summary, "The PR is [open](https://x/pull/1).")
        XCTAssertEqual(first.boardRow?.statusSummary.map(SummaryFreshness.init), .stale(messages: 2))
        let second = try XCTUnwrap(result.sessions.first { $0.id == 8 })
        XCTAssertNotNil(second.boardRow)
        XCTAssertNil(second.boardRow?.statusSummary)
    }

    func testAServerWithoutBoardRowsStillLists() async throws {
        let (api, _) = client([{ _ in
            Fixtures.json(200, ["sessions": [["id": 7, "status": "needs_input"]], "pagination": ["total_pages": 1]])
        }])
        let result = try await api.sessions(.default, board: .onBoard, view: .yourBoard)
        XCTAssertEqual(result.sessions.map(\.id), [7])
        XCTAssertNil(result.sessions.first?.boardRow)
    }

    func testSearchAsksForTheRowsToo() async throws {
        let (api, transport) = client([{ _ in
            Fixtures.json(200, [
                "sessions": [["id": 7, "status": "needs_input"]],
                "board_rows": ["7": ["agent_root": "zimmer", "status_summary": ["summary": "x"]]],
            ])
        }])
        let result = try await api.search("x", contents: false, filters: .default, board: .onBoard)
        let query = URLComponents(url: try XCTUnwrap(transport.sent.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "include" }?.value, "board_row")
        XCTAssertEqual(result.sessions.first?.boardRow?.statusSummary?.summary, "x")
    }

    func testFreshnessReadsAsTheDashboardsChip() {
        XCTAssertEqual(SummaryFreshness(StatusSummary(summary: "x", generating: true, messagesSinceGenerated: 4)), .regenerating)
        XCTAssertEqual(SummaryFreshness(StatusSummary(summary: "x", messagesSinceGenerated: 4)), .stale(messages: 4))
        XCTAssertEqual(SummaryFreshness(StatusSummary(summary: "x", messagesSinceGenerated: 0)), .current)
        XCTAssertEqual(SummaryFreshness(StatusSummary(summary: "x")), .current)
    }

    func testTheRecordedAgentRootWinsOverTheResolvedOne() {
        var session = SessionSummary(id: 1, status: .running, agentRoot: "recorded")
        session.boardRow = BoardRow(agentRoot: "resolved")
        XCTAssertEqual(session.agentRoot, "recorded")
        session.metadata = nil
        XCTAssertEqual(session.agentRoot, "resolved")
    }

    private func row(_ id: Int, priority: Bool) -> SessionSummary {
        SessionSummary(id: id, status: .waiting, priorityClass: priority ? "priority" : "spot")
    }

    func testADropNamesTheNearestRowsOfItsOwnClass() {
        // P1 P2 | S3 S4 S5, with S5 dragged between P1 and P2.
        let rows = [row(1, priority: true), row(5, priority: false), row(2, priority: true), row(3, priority: false), row(4, priority: false)]
        let neighbours = BoardView.dropNeighbours(rows, at: 1)
        XCTAssertNil(neighbours.above, "no spot row above it")
        XCTAssertEqual(neighbours.below, 3)
    }

    func testADropWithinItsClassNamesTheRowsBesideIt() {
        let rows = [row(1, priority: true), row(3, priority: false), row(5, priority: false), row(4, priority: false)]
        let neighbours = BoardView.dropNeighbours(rows, at: 2)
        XCTAssertEqual(neighbours.above, 3)
        XCTAssertEqual(neighbours.below, 4)
    }

    func testOnlyYourBoardAndRankedAreReordered() {
        XCTAssertEqual(BoardView.allCases.filter(\.isReorderable), [.yourBoard, .ranked])
    }
}
