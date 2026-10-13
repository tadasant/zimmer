import XCTest

/// The session page reads again on its own, opens at the newest message, and keeps what you
/// typed — against the `-ZimmerFixture` in-memory Zimmer.
@MainActor
final class LiveUpdatesUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_running_session_shows_new_messages_without_a_pull() throws {
        // -ZimmerFixtureLive: the running session's agent adds a line on each read after the first.
        let app = launch(["-ZimmerFixtureLive", "-ZimmerFixtureOpenSession", "1042"])
        XCTAssertTrue(app.descendants(matching: .any)["followup.field"].waitForExistence(timeout: timeout))
        let newLine = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Still working — step 1 done.")).firstMatch
        XCTAssertTrue(newLine.waitForExistence(timeout: timeout), "a new message appears with nothing touched")
    }

    func test_reading_back_is_not_pulled_to_the_end_by_new_messages() throws {
        let app = launch(["-ZimmerFixtureLive", "-ZimmerFixtureOpenSession", "1042"])
        let first = app.descendants(matching: .any)["detail.message.0"]
        XCTAssertTrue(first.waitForExistence(timeout: timeout))
        for _ in 0..<8 where !first.isHittable { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(first.isHittable, "scrolled back to the start")
        // Two polls' worth of new lines arrive while reading back.
        let later = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "step 2 done")).firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: timeout))
        XCTAssertTrue(first.isHittable, "still where the reader left it")
    }

    func test_a_session_opens_at_its_newest_message() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1044"])
        let newest = app.descendants(matching: .any)["detail.message.6"]
        XCTAssertTrue(newest.waitForExistence(timeout: timeout))
        let field = app.descendants(matching: .any)["followup.field"]
        let onScreen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: newest)
        XCTAssertEqual(XCTWaiter().wait(for: [onScreen], timeout: timeout), .completed, "the newest message is in view")
        XCTAssertLessThan(newest.frame.maxY, field.frame.minY + 1, "above the composer, not under it")
    }

    func test_a_draft_survives_leaving_the_session() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1035"])
        let field = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Try 17 on a copy first")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let row = app.descendants(matching: .any)["session.row.1035"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        row.tap()
        let reopened = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(reopened.waitForExistence(timeout: timeout))
        let kept = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Try 17 on a copy first"), object: reopened)
        XCTAssertEqual(XCTWaiter().wait(for: [kept], timeout: timeout), .completed, "the words are still there")
    }

    // MARK: - Helpers

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }
}
