import XCTest
@testable import ZimmerKit

/// A row action shows before the server answers, and a read that lands meanwhile must not
/// undo it: the changes in flight are laid over every read until each is answered.
final class PendingBoardChangesTests: XCTestCase {
    private let rows = [
        SessionSummary(id: 1, status: .needsInput),
        SessionSummary(id: 2, status: .running),
        SessionSummary(id: 3, status: .waiting),
    ]

    func testNothingPendingLeavesAReadAlone() {
        let pending = PendingBoardChanges()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(pending.overlay(rows), rows)
    }

    func testARemovedRowIsLeftOutOfEveryReadUntilTheAnswer() {
        var pending = PendingBoardChanges()
        let ticket = pending.begin(2, .removed)
        XCTAssertTrue(pending.isPending(2))
        XCTAssertEqual(pending.overlay(rows).map(\.id), [1, 3], "a read from before the trash does not put the row back")
        XCTAssertTrue(pending.end(ticket))
        XCTAssertEqual(pending.overlay(rows).map(\.id), [1, 2, 3], "answered, the server's list is the truth again")
        XCTAssertTrue(pending.isEmpty)
    }

    func testAReplacedRowStandsInForTheServersCopy() {
        var pending = PendingBoardChanges()
        var snoozed = rows[0]
        snoozed.visibility = .snoozed
        pending.begin(1, .replaced(snoozed))
        let shown = pending.overlay(rows)
        XCTAssertEqual(shown.map(\.id), [1, 2, 3], "the row stays in its place")
        XCTAssertEqual(shown[0].visibility, .snoozed)
    }

    func testAReplacedRowTheListDoesNotAdmitLeaves() {
        var pending = PendingBoardChanges()
        var snoozed = rows[0]
        snoozed.visibility = .snoozed
        pending.begin(1, .replaced(snoozed))
        // The board shows visible rows only, as "On board" does.
        let shown = pending.overlay(rows) { $0.visibility != .snoozed }
        XCTAssertEqual(shown.map(\.id), [2, 3])
    }

    func testAReplacedRowTheServerDoesNotListYetJoinsWhenItBelongs() {
        var pending = PendingBoardChanges()
        // Restored from the trash: the server's read still hides it, the board shows the living.
        let restored = SessionSummary(id: 9, status: .needsInput)
        pending.begin(9, .replaced(restored))
        XCTAssertEqual(pending.overlay(rows) { $0.status != .archived }.map(\.id), [1, 2, 3, 9])
        XCTAssertEqual(pending.overlay(rows) { $0.status == .archived }.map(\.id), [1, 2, 3], "not on a list it does not belong to")
    }

    func testAReplacedRowKeepsTheReadsBoardRow() {
        var pending = PendingBoardChanges()
        var read = rows
        read[0].boardRow = BoardRow(agentRoot: "zimmer")
        var renamed = rows[0]
        renamed.title = "Renamed"
        pending.begin(1, .replaced(renamed))
        let shown = pending.overlay(read)
        XCTAssertEqual(shown[0].title, "Renamed")
        XCTAssertEqual(shown[0].boardRow?.agentRoot, "zimmer", "the copy made here has no board row; the read's rides along")
    }

    func testTheNewestChangeToARowWinsAndAnOlderAnswerEndsNothing() {
        var pending = PendingBoardChanges()
        var snoozed = rows[1]
        snoozed.visibility = .snoozed
        let snooze = pending.begin(2, .replaced(snoozed))
        let trash = pending.begin(2, .removed)
        XCTAssertEqual(pending.overlay(rows).map(\.id), [1, 3], "the trash, asked second, is what the board shows")
        XCTAssertFalse(pending.end(snooze), "the snooze's answer is not the one the board waits on")
        XCTAssertTrue(pending.isPending(2))
        XCTAssertEqual(pending.overlay(rows).map(\.id), [1, 3])
        XCTAssertTrue(pending.end(trash))
        XCTAssertFalse(pending.isPending(2))
    }

    func testEndingTwiceIsHarmless() {
        var pending = PendingBoardChanges()
        let ticket = pending.begin(1, .removed)
        XCTAssertTrue(pending.end(ticket))
        XCTAssertFalse(pending.end(ticket))
        XCTAssertEqual(pending.ids, [])
    }

    func testIdsNameEveryRowWithAChangeOut() {
        var pending = PendingBoardChanges()
        pending.begin(1, .removed)
        pending.begin(3, .removed)
        XCTAssertEqual(pending.ids, [1, 3])
    }
}
