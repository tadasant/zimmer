import XCTest

/// The board's filters combine, as on the web: several statuses at once, then a scheduling
/// class on top, against the `-ZimmerFixture` in-memory Zimmer.
@MainActor
final class BoardFiltersUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_statuses_and_a_scheduling_class_combine_and_reset() throws {
        let app = launch()
        let more = app.buttons["filter.more"]
        XCTAssertTrue(more.waitForExistence(timeout: timeout))
        XCTAssertTrue(row(app, 1038).waitForExistence(timeout: timeout))
        XCTAssertFalse(row(app, 1027).exists, "Needs input only, by default")

        // Needs input and Failed together.
        more.tap()
        let failed = app.switches["filters.status.failed"]
        XCTAssertTrue(failed.waitForExistence(timeout: timeout))
        tapSwitch(failed)
        app.buttons["filters.apply"].tap()
        XCTAssertTrue(row(app, 1027).waitForExistence(timeout: timeout), "the failed session joins the needs-input ones")
        XCTAssertTrue(row(app, 1038).exists)
        XCTAssertTrue(app.descendants(matching: .any)["filter.summary"].exists)

        // Then only priority sessions among them.
        more.tap()
        let priority = app.buttons["Priority"].firstMatch
        XCTAssertTrue(priority.waitForExistence(timeout: timeout))
        priority.tap()
        app.buttons["filters.apply"].tap()
        XCTAssertTrue(waitForDisappearance(row(app, 1027)), "a spot session leaves")
        XCTAssertTrue(row(app, 1038).exists, "the priority one stays")

        // Reset is one tap back to the default.
        app.buttons["filter.reset"].tap()
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["filter.summary"]))
        XCTAssertTrue(row(app, 1035).waitForExistence(timeout: timeout))
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureBoard", "all"]
        app.launch()
        return app
    }

    private func row(_ app: XCUIApplication, _ id: Int) -> XCUIElement {
        app.descendants(matching: .any)["session.row.\(id)"]
    }

    /// A Form toggle's switch is tapped on its right edge, where the control is.
    private func tapSwitch(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
