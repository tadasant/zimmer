import XCTest

/// The board reads again when it comes back to the front, so a session trashed somewhere else
/// leaves it without a pull — against the `-ZimmerFixture` in-memory Zimmer.
@MainActor
final class BoardStaysCurrentUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_session_trashed_elsewhere_leaves_the_board_when_you_come_back_to_it() throws {
        // -ZimmerFixtureTrashedElsewhere: 1035 goes to the trash once another session's page is read.
        let app = launch(["-ZimmerFixtureTrashedElsewhere", "1035"])
        let trashed = app.descendants(matching: .any)["session.row.1035"]
        XCTAssertTrue(trashed.waitForExistence(timeout: timeout), "on the board at launch")

        let other = app.descendants(matching: .any)["session.row.1038"]
        XCTAssertTrue(other.waitForExistence(timeout: timeout))
        other.tap()
        XCTAssertTrue(app.descendants(matching: .any)["followup.field"].waitForExistence(timeout: timeout))
        // Long enough on the page that the board's launch read is no longer fresh.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "reading the session")], timeout: 6)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(other.waitForExistence(timeout: timeout), "back on the board")
        // Well inside the half-minute poll: the board read on coming back, not on its clock.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: trashed)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "the trashed session left without a pull")
    }

    // MARK: - Helpers

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }
}
