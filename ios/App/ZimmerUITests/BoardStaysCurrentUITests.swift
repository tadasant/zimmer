import XCTest

/// The board reads again when you come back to its tab, so a session trashed somewhere else
/// leaves it without a pull — against the `-ZimmerFixture` in-memory Zimmer.
@MainActor
final class BoardStaysCurrentUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_session_trashed_elsewhere_leaves_the_board_when_you_come_back_to_its_tab() throws {
        // -ZimmerFixtureTrashedElsewhere: 1035 goes to the trash once the Inbox is read.
        let app = launch(["-ZimmerFixtureTrashedElsewhere", "1035"])
        let trashed = app.descendants(matching: .any)["session.row.1035"]
        XCTAssertTrue(trashed.waitForExistence(timeout: timeout), "on the board at launch")

        app.tabBars.buttons["Inbox"].tap()
        // Long enough on the Inbox that the board's launch read is no longer fresh.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "reading the inbox")], timeout: 6)
        app.tabBars.buttons["Sessions"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].waitForExistence(timeout: timeout), "back on the board")
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
