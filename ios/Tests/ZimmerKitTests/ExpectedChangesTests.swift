import XCTest
@testable import ZimmerKit

/// What a row shows at the tap, before the server has answered: the row as the action is
/// expected to leave it.
final class ExpectedChangesTests: XCTestCase {
    private let until = Date(timeIntervalSince1970: 1_800_000_000)

    func testVisibilityFollowsTheChange() {
        var row = SessionSummary(id: 1, status: .needsInput, visibility: .visible)
        row.expect(.snoozed(until: until))
        XCTAssertEqual(row.boardVisibility, .snoozed)
        XCTAssertEqual(row.snoozedUntil, until)
        row.expect(.hidden)
        XCTAssertEqual(row.boardVisibility, .hidden)
        XCTAssertNil(row.snoozedUntil)
        row.expect(.visible)
        XCTAssertEqual(row.boardVisibility, .visible)
        XCTAssertEqual(row.effectiveVisibility, .visible, "the board reads the effective visibility, so it follows too")
    }

    func testTrashAndRestore() {
        var row = SessionSummary(id: 1, status: .running)
        row.expectTrashed(at: until)
        XCTAssertEqual(row.status, .archived)
        XCTAssertEqual(row.archivedAt, until)
        XCTAssertFalse(BoardFilters.allUnarchived.admits(row), "a list of the living drops it")
        row.expectRestored()
        XCTAssertEqual(row.status, .needsInput)
        XCTAssertNil(row.archivedAt)
        XCTAssertTrue(BoardFilters.allUnarchived.admits(row))
    }

    func testStatusActions() {
        var row = SessionSummary(id: 1, status: .running)
        row.expectPaused()
        XCTAssertEqual(row.status, .needsInput)
        row.expectRestarted()
        XCTAssertEqual(row.status, .waiting)
    }

    func testPriorityCrossesTheHalves() {
        var row = SessionSummary(id: 1, status: .waiting, priorityClass: "spot", precedence: 3)
        row.expectPriority(true)
        XCTAssertTrue(row.isPriority)
        XCTAssertEqual(row.schedulingClass, "priority")
        XCTAssertEqual(row.precedence, 3, "where in the half it lands is the server's say")
    }

    func testTheEditableFields() {
        var row = SessionSummary(id: 1, status: .needsInput)
        row.expectTitle("Renamed")
        row.expectNotes("")
        row.expectGoal("Ship it")
        row.expectPrecedence(7)
        row.expectHeartbeat(enabled: true)
        row.expectHeartbeat(everySeconds: 600)
        row.expectModel("claude-opus-5-5")
        XCTAssertEqual(row.title, "Renamed")
        XCTAssertNil(row.notes, "an emptied field reads as none, as the server answers it")
        XCTAssertEqual(row.goal, "Ship it")
        XCTAssertEqual(row.precedence, 7)
        XCTAssertEqual(row.heartbeatEnabled, true)
        XCTAssertEqual(row.heartbeatIntervalSeconds, 600)
        XCTAssertEqual(row.model, "claude-opus-5-5")
    }

    func testEffortChosenAndDefaulted() {
        var row = SessionSummary(id: 1, status: .needsInput, effort: EffortSummary(level: "medium", source: "default", default: "medium", levels: ["low", "medium", "high"]))
        row.expectEffort("high")
        XCTAssertEqual(row.effort?.level, "high")
        XCTAssertEqual(row.effort?.source, "session")
        row.expectEffort(nil)
        XCTAssertEqual(row.effort?.level, "medium", "the model's default is back in force")
        XCTAssertEqual(row.effort?.source, "default")
        XCTAssertEqual(row.effort?.levels, ["low", "medium", "high"], "the levels offered are kept")
    }
}
