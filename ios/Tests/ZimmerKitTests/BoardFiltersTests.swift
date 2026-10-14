import XCTest
@testable import ZimmerKit

/// The board's filters combine, as the web UI's filter form does, and the chips are presets of them.
final class BoardFiltersTests: XCTestCase {
    func testStatusesGoAsOneCommaSeparatedListAndArchivedBringsTheTrash() {
        var filters = BoardFilters(statuses: [.failed, .needsInput])
        XCTAssertEqual(filters.query["status"], "needs_input,failed", "in the web UI's order")
        XCTAssertNil(filters.query["show_archived"])
        filters.toggle(.archived)
        XCTAssertEqual(filters.query["status"], "needs_input,failed,archived")
        XCTAssertEqual(filters.query["show_archived"], "true")
    }

    func testEveryFilterIsSent() {
        let filters = BoardFilters(statuses: [.waiting], schedulingClass: "priority", agentRoot: "zimmer", genesis: "schedule")
        XCTAssertEqual(filters.query, ["per_page": "100", "status": "waiting", "priority_class": "priority", "agent_root": "zimmer", "genesis": "schedule"])
        XCTAssertNil(BoardFilters.allUnarchived.query["status"], "no statuses asks for every unarchived session")
    }

    func testTheChipsArePresetsAndAnyOtherCombinationIsCustom() {
        XCTAssertEqual(BoardFilters.default.preset, .needsInput)
        XCTAssertEqual(BoardFilters.allUnarchived.preset, .active)
        XCTAssertEqual(BoardFilters(statuses: [.waiting]).preset, .waiting)
        XCTAssertNil(BoardFilters(statuses: [.needsInput, .failed]).preset)
        XCTAssertNil(BoardFilters(statuses: [.needsInput], schedulingClass: "priority").preset)
        XCTAssertEqual(SessionFilter.allCases.first, .needsInput)
    }

    func testARowIsKeptOnlyWhenEveryFilterAdmitsIt() {
        let filters = BoardFilters(statuses: [.needsInput, .failed], schedulingClass: "priority", agentRoot: "zimmer")
        let match = SessionSummary(id: 1, status: .failed, priorityClass: "priority", agentRoot: "zimmer")
        XCTAssertTrue(filters.admits(match))
        XCTAssertFalse(filters.admits(SessionSummary(id: 2, status: .running, priorityClass: "priority", agentRoot: "zimmer")))
        XCTAssertFalse(filters.admits(SessionSummary(id: 3, status: .failed, priorityClass: "spot", agentRoot: "zimmer")))
        XCTAssertFalse(filters.admits(SessionSummary(id: 4, status: .failed, priorityClass: "priority", agentRoot: "other")))
        XCTAssertFalse(BoardFilters.allUnarchived.admits(SessionSummary(id: 5, status: .archived)))
        XCTAssertTrue(BoardFilters(genesis: "schedule").admits(SessionSummary(id: 6, status: .waiting, genesis: "schedule")))
    }

    func testTheSummarySaysWhatIsShown() {
        XCTAssertEqual(BoardFilters(statuses: [.failed, .needsInput], schedulingClass: "priority", agentRoot: "zimmer").summary,
                       "Needs input, Failed · Priority · zimmer")
        XCTAssertEqual(BoardFilters.allUnarchived.summary, "All unarchived")
        XCTAssertEqual(BoardFilters.all.summary, "All statuses")
    }

    func testFiltersSurviveBeingWrittenDown() throws {
        let filters = BoardFilters(statuses: [.waiting, .failed], schedulingClass: "spot", agentRoot: "zimmer", genesis: "api")
        let decoded = try JSONDecoder().decode(BoardFilters.self, from: JSONEncoder().encode(filters))
        XCTAssertEqual(decoded, filters)
    }

    func testTheFakeNarrowsByEveryFilterTogether() async throws {
        let api = FakeZimmerAPI()
        let both = try await api.sessions(BoardFilters(statuses: [.needsInput, .failed]), board: .all).sessions.map(\.id)
        XCTAssertEqual(Set(both), [1038, 1035, 1027, 1044])
        let priority = try await api.sessions(BoardFilters(statuses: [.needsInput, .failed], schedulingClass: "priority"), board: .all).sessions.map(\.id)
        XCTAssertEqual(priority, [1038])
        let scheduled = try await api.sessions(BoardFilters(genesis: "schedule"), board: .all).sessions.map(\.id)
        XCTAssertEqual(scheduled, [1031])
    }

    func testARankedViewOpensOnEverythingThatCanStillRun() {
        XCTAssertEqual(BoardFilters.ranked.orderedStatuses, [.waiting, .running, .needsInput, .failed])
    }

    func testATitleSearchWithMorePagesThanThePhoneReadsSaysItIsIncomplete() async throws {
        let transport = ScriptedTransport([{ _ in Fixtures.json(200, ["sessions": [], "pagination": ["total_pages": 3]]) }])
        let api = ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport)
        let result = try await api.search("deploy", contents: false, filters: BoardFilters(statuses: [.needsInput, .failed]), board: .all)
        XCTAssertFalse(result.complete)
        let query = URLComponents(url: transport.sent[0].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "status" }?.value, "needs_input,failed")
    }
}
