import XCTest
@testable import ZimmerKit

/// Your board v2: Last Touched's rows under the person's own categories, the app's default view.
final class BoardV2Tests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func query(_ request: HTTPRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private let now = Date(timeIntervalSince1970: 1_791_700_000)
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private let categories = [
        BoardCategory(id: 7, name: "Research", position: 0),
        BoardCategory(id: 8, name: "Infra", position: 1, collapsed: true),
        BoardCategory(id: 9, name: "Someday", position: 2, visibility: .backlogged, onBoard: false, sessionCount: 4),
    ]

    private var rows: [SessionSummary] {
        [
            SessionSummary(id: 1, status: .running, createdAt: ago(10)),
            SessionSummary(id: 2, status: .needsInput, createdAt: ago(50), lastUserActivityAt: ago(1)),
            SessionSummary(id: 3, status: .waiting, createdAt: ago(30), boardCategoryID: 7),
            SessionSummary(id: 4, status: .failed, createdAt: ago(40), lastUserActivityAt: ago(2), boardCategoryID: 7),
            SessionSummary(id: 5, status: .waiting, createdAt: ago(5), boardCategoryID: 8),
            // A category deleted since: Uncategorized, as the server's ON DELETE SET NULL makes it.
            SessionSummary(id: 6, status: .waiting, createdAt: ago(60), boardCategoryID: 99),
            // Moved into a tucked-away category here: it leaves the board, as the server would.
            SessionSummary(id: 7, status: .waiting, createdAt: ago(3), boardCategoryID: 9),
        ]
    }

    func testTheAppOpensOnYourBoardV2() {
        XCTAssertEqual(BoardView.defaultView, .boardV2)
        XCTAssertEqual(BoardView.boardV2.rawValue, "board_v2", "the web UI's ?view=")
        XCTAssertEqual(BoardView.boardV2.label, "Your board v2")
        XCTAssertFalse(BoardView.boardV2.isReorderable, "rows are placed by category and last touch, not dragged into an order")
    }

    func testUncategorizedFirstThenEachCategoryOnTheBoardNewestTouchedFirst() {
        let sections = BoardView.boardV2.sections(rows, categories: categories)
        XCTAssertEqual(sections.map(\.title), ["Uncategorized", "Research", "Infra"], "the backlogged category is not a section")
        XCTAssertEqual(sections[0].sessions.map(\.id), [2, 1, 6], "2 touched a minute ago; then by when created")
        XCTAssertEqual(sections[1].sessions.map(\.id), [4, 3])
        XCTAssertEqual(sections.map(\.id), ["uncategorized", "category.7", "category.8"], "keyed by category, so a name cannot collide")
    }

    func testACollapsedCategoryKeepsItsCountAndDrawsNoRows() {
        let infra = BoardView.boardV2.sections(rows, categories: categories)[2]
        XCTAssertTrue(infra.isCollapsed)
        XCTAssertEqual(infra.sessions, [])
        XCTAssertEqual(infra.count, 1)
    }

    func testWithNoCategoriesEverySessionIsUncategorized() {
        let sections = BoardView.boardV2.sections(rows)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].sessions.count, rows.count)
    }

    func testTheOtherViewsIgnoreCategories() {
        XCTAssertEqual(BoardView.lastTouched.sections(rows, categories: categories).count, 1)
    }

    func testTheViewIsReadFromTheServerWithItsCategories() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, [
                "sessions": [["id": 1, "status": "running", "board_category_id": 7], ["id": 2, "status": "needs_input", "board_category_id": NSNull()]],
                "board_categories": [
                    ["id": 7, "name": "Research", "position": 0, "collapsed": false, "visibility": "visible", "on_board": true, "session_count": 1],
                    ["id": 9, "name": "Someday", "position": 1, "collapsed": false, "visibility": "backlogged", "on_board": false, "session_count": 3],
                ],
                "pagination": ["total_pages": 1], "truncated": true,
            ]) },
        ])

        let result = try await api.sessions(SessionFilter.active.filters, board: .onBoard, view: .boardV2)

        XCTAssertEqual(query(transport.sent[0])["view"], "board_v2")
        XCTAssertNil(query(transport.sent[0])["page"], "one page, as the User view")
        XCTAssertEqual(result.sessions.map(\.boardCategoryID), [7, nil])
        XCTAssertEqual(result.categories?.map(\.name), ["Research", "Someday"])
        XCTAssertEqual(result.categories?.map(\.onBoard), [true, false])
        XCTAssertEqual(result.categories?.last?.visibility, .backlogged)
        XCTAssertEqual(result.categories?.last?.sessionCount, 3)
        XCTAssertFalse(result.complete)
    }

    func testACategoryMissingItsOptionalFieldsStillDecodes() throws {
        let category = try ZimmerJSON.decoder.decode(BoardCategory.self, from: Data(#"{"id": 3, "name": "Infra", "collapsed": "yes"}"#.utf8))
        XCTAssertEqual(category.name, "Infra")
        XCTAssertFalse(category.collapsed)
        XCTAssertTrue(category.onBoard)
    }

    func testTheWritesHitTheirRoutes() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["session": ["id": 5, "status": "running", "board_category_id": 7]]) },
            { _ in Fixtures.json(200, ["session": ["id": 5, "status": "running", "board_category_id": NSNull()]]) },
            { _ in Fixtures.json(200, ["board_category": ["id": 7, "name": "Research", "collapsed": true, "on_board": true]]) },
            { _ in Fixtures.json(200, ["board_category": ["id": 9, "name": "Someday", "visibility": "visible", "on_board": true]]) },
        ])

        let moved = try await api.assignBoardCategory(5, categoryID: 7)
        let back = try await api.assignBoardCategory(5, categoryID: nil)
        let collapsed = try await api.setBoardCategoryCollapsed(7, collapsed: true)
        let woken = try await api.wakeBoardCategory(9)

        XCTAssertEqual(moved.boardCategoryID, 7)
        XCTAssertNil(back.boardCategoryID)
        XCTAssertTrue(collapsed.collapsed)
        XCTAssertTrue(woken.onBoard)
        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, [
            "PATCH /api/v1/sessions/5/board_category", "PATCH /api/v1/sessions/5/board_category",
            "PATCH /api/v1/board_categories/7", "PATCH /api/v1/board_categories/9/visibility",
        ])
        let bodies = transport.sent.map { try? JSONSerialization.jsonObject(with: $0.body ?? Data()) as? [String: Any] }
        XCTAssertEqual(bodies[0]?["board_category_id"] as? Int, 7)
        XCTAssertTrue(bodies[1]?["board_category_id"] is NSNull, "Uncategorized is an explicit null")
        XCTAssertEqual(bodies[2]?["collapsed"] as? Bool, true)
        XCTAssertEqual(bodies[3]?["visibility"] as? String, "visible")
    }

    func testTheFixtureGroupsMovesCollapsesAndWakesAsTheServerDoes() async throws {
        let fake = FakeZimmerAPI()
        let first = try await fake.sessions(SessionFilter.active.filters, board: .all, view: .boardV2)
        XCTAssertFalse(first.sessions.contains { $0.id == 1029 }, "the backlogged category's row is counted, not listed")
        XCTAssertEqual(first.categories?.map(\.name), ["iOS app", "Ops", "Someday"])
        XCTAssertEqual(first.categories?.last?.onBoard, false)

        let moved = try await fake.assignBoardCategory(1035, categoryID: 1)
        XCTAssertEqual(moved.boardCategoryID, 1)
        await XCTAssertThrowsAsync(try await fake.assignBoardCategory(1035, categoryID: 404), "an unknown category is refused")

        let opened = try await fake.setBoardCategoryCollapsed(2, collapsed: false)
        XCTAssertFalse(opened.collapsed)
        _ = try await fake.wakeBoardCategory(3)
        let after = try await fake.sessions(SessionFilter.active.filters, board: .all, view: .boardV2)
        XCTAssertTrue(after.categories?.allSatisfy(\.onBoard) ?? false)
        XCTAssertTrue(after.sessions.contains { $0.id == 1029 }, "a woken category's rows come back")
    }
}
