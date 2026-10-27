import XCTest
@testable import ZimmerKit

/// CarPlay fit on the phone: the mark as the REST session carries it, the board's filter on it,
/// and the menu's write (`PATCH /api/v1/sessions/:id/carplay_fit`).
final class CarplayFitTests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    private func body(_ request: HTTPRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: String])
    }

    private static func session(_ fields: [String: Any]) -> [String: Any] {
        ["id": 5, "status": "needs_input"].merging(fields) { $1 }
    }

    private static var marked: [String: Any] { session([
        "carplay_fit": "laptop_only", "effective_carplay_fit": "laptop_only", "carplay_fit_reason": "credential",
        "carplay_fit_source": "auto", "carplay_fit_set_at": "2026-10-27T17:05:00Z", "carplay_fit_line_count": 412,
        "carplay_fit_summary": "Laptop only (a credential) · auto · current",
    ]) }

    func testTheMarkDecodesWithItsProvenance() async throws {
        let (api, _) = client([{ _ in Fixtures.json(200, ["session": Self.marked]) }])
        let session = try await api.session(5).session
        XCTAssertEqual(session.currentCarplayFit, .laptopOnly)
        XCTAssertEqual(session.currentCarplayFitReason, .credential)
        XCTAssertEqual(session.carplayFitSource, "auto")
        XCTAssertEqual(session.carplayFitLineCount, 412)
        XCTAssertNotNil(session.carplayFitSetAt)
        XCTAssertEqual(session.carplayFitSummary, "Laptop only (a credential) · auto · current")
    }

    func testAStaleMarkIsNotInForceAndAnUnknownOneDoesNotBreakTheRow() async throws {
        let (api, _) = client([{ _ in
            Fixtures.json(200, ["sessions": [
                Self.session(["id": 6, "carplay_fit": "carplay_ok", "effective_carplay_fit": NSNull(), "carplay_fit_reason": "decision",
                              "carplay_fit_summary": "CarPlay-ok (a decision) · human · stale, 3 message(s) since"]),
                Self.session(["id": 7, "carplay_fit": "hands_free", "effective_carplay_fit": "hands_free", "carplay_fit_reason": "a_new_one"]),
                Self.session(["id": 8]),
            ]])
        }])
        let rows = try await api.sessions(.allUnarchived, board: .all).sessions
        XCTAssertEqual(rows.map(\.id), [6, 7, 8])
        XCTAssertNil(rows[0].currentCarplayFit, "a mark the session has moved past is not in force")
        XCTAssertNil(rows[0].currentCarplayFitReason)
        XCTAssertEqual(rows[0].carplayFit, "carplay_ok", "the stored mark is still read")
        XCTAssertNil(rows[1].currentCarplayFit, "a value from a later server reads as no mark")
        XCTAssertNil(rows[2].carplayFit, "an older server sends nothing")
    }

    func testAMarkIsPatchedWithItsReasonAndAClearSaysClear() async throws {
        let applied: ScriptedTransport.Handler = { _ in
            Fixtures.json(200, ["session": Self.marked, "carplay_fit_result": ["applied": true, "message": "CarPlay fit set to laptop_only."]])
        }
        let (api, transport) = client([applied, applied, applied])
        let result = try await api.setCarplayFit(5, .mark(.laptopOnly, reason: .credential))
        _ = try await api.setCarplayFit(5, .mark(.carplayOk, reason: nil))
        _ = try await api.setCarplayFit(5, .clear)

        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, Array(repeating: "PATCH /api/v1/sessions/5/carplay_fit", count: 3))
        XCTAssertEqual(try body(transport.sent[0]), ["carplay_fit": "laptop_only", "carplay_fit_reason": "credential"])
        XCTAssertEqual(try body(transport.sent[1]), ["carplay_fit": "carplay_ok"])
        XCTAssertEqual(try body(transport.sent[2]), ["carplay_fit": "clear"])
        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.session.currentCarplayFit, .laptopOnly)
    }

    func testAWriteAStandingMarkOutranksIsReportedNotThrown() async throws {
        let (api, _) = client([{ _ in
            Fixtures.json(200, ["session": Self.marked, "carplay_fit_result": [
                "applied": false, "message": "CarPlay Fit Kept: a human mark at the same position outranks this write.",
            ]])
        }])
        let result = try await api.setCarplayFit(5, .mark(.carplayOk, reason: .decision))
        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.message, "CarPlay Fit Kept: a human mark at the same position outranks this write.")
        XCTAssertEqual(result.session.currentCarplayFit, .laptopOnly, "the standing mark is what is shown")
    }

    func testEveryReasonBelongsToExactlyOneSide() {
        let sides = CarplayFit.allCases.flatMap(\.reasons)
        XCTAssertEqual(Set(sides), Set(CarplayFitReason.allCases))
        XCTAssertEqual(sides.count, CarplayFitReason.allCases.count)
        XCTAssertEqual(CarplayFitChange.mark(.laptopOnly, reason: .longRead).done, "Marked Laptop only (a long read)")
        XCTAssertEqual(CarplayFitChange.clear.done, "CarPlay fit cleared")
    }

    // MARK: - The board's filter

    func testTheFilterIsSentCountedAndSummarized() {
        let filters = BoardFilters(statuses: [.needsInput], carplayFit: .notLaptopOnly)
        XCTAssertEqual(filters.query["carplay_fit"], "not_laptop_only")
        XCTAssertEqual(filters.refinementCount, 1)
        XCTAssertEqual(filters.summary, "Needs input · Not laptop-only")
        XCTAssertNil(BoardFilters.default.query["carplay_fit"], "unset by default: every row")
        XCTAssertNil(filters.preset, "a CarPlay fit on top of a chip is a combination of its own")
    }

    func testTheFilterReadsTheMarkInForceAsTheServerDoes() {
        var ok = SessionSummary(id: 1, status: .needsInput)
        ok.carplayFit = "carplay_ok"; ok.effectiveCarplayFit = "carplay_ok"
        var laptop = SessionSummary(id: 2, status: .needsInput)
        laptop.carplayFit = "laptop_only"; laptop.effectiveCarplayFit = "laptop_only"
        var stale = SessionSummary(id: 3, status: .needsInput)
        stale.carplayFit = "laptop_only"
        let untagged = SessionSummary(id: 4, status: .needsInput)
        let rows = [ok, laptop, stale, untagged]

        func ids(_ filter: CarplayFitFilter) -> [Int] { rows.filter(BoardFilters(carplayFit: filter).admits).map(\.id) }
        XCTAssertEqual(ids(.notLaptopOnly), [1, 3, 4], "judged good plus not judged; a stale laptop mark counts as untagged")
        XCTAssertEqual(ids(.carplayOk), [1])
        XCTAssertEqual(ids(.laptopOnly), [2])
        XCTAssertEqual(ids(.untagged), [3, 4])
    }

    func testTheFilterSurvivesBeingWrittenDownAndOlderFiltersStillRead() throws {
        let filters = BoardFilters(statuses: [.needsInput], carplayFit: .laptopOnly)
        let decoded = try JSONDecoder().decode(BoardFilters.self, from: JSONEncoder().encode(filters))
        XCTAssertEqual(decoded, filters)
        XCTAssertEqual(decoded.carplayFitFilter, .laptopOnly)

        let older = try JSONDecoder().decode(BoardFilters.self, from: Data(#"{"statuses":["needs_input"],"agentRoot":"zimmer"}"#.utf8))
        XCTAssertNil(older.carplayFit, "filters written by a build before this one read as every row")
        XCTAssertEqual(older.agentRoot, "zimmer")
    }

    // MARK: - The fixture

    func testTheFixtureMarksNarrowsAndTakesAHumanMark() async throws {
        let fake = FakeZimmerAPI()
        let driving = try await fake.sessions(BoardFilters(statuses: [.needsInput], carplayFit: .notLaptopOnly), board: .all).sessions.map(\.id)
        XCTAssertEqual(Set(driving), [1038, 1035], "the parity audit is a long read for the laptop")

        let result = try await fake.setCarplayFit(1035, .mark(.laptopOnly, reason: .manualSteps))
        XCTAssertTrue(result.applied)
        XCTAssertEqual(result.session.carplayFitSource, "human")
        XCTAssertEqual(result.session.carplayFitSummary, "Laptop only (manual steps) · human · current")
        let afterwards = try await fake.sessions(BoardFilters(statuses: [.needsInput], carplayFit: .notLaptopOnly), board: .all).sessions.map(\.id)
        XCTAssertEqual(afterwards, [1038])

        let cleared = try await fake.setCarplayFit(1035, .clear)
        XCTAssertNil(cleared.session.carplayFit)
        XCTAssertNil(cleared.session.carplayFitSummary)
    }
}
