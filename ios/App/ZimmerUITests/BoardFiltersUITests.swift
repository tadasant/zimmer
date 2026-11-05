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
        flip(failed)
        app.buttons["filters.apply"].tap()
        XCTAssertTrue(row(app, 1027).waitForExistence(timeout: timeout), "the failed session joins the needs-input ones")
        XCTAssertTrue(row(app, 1038).exists)
        XCTAssertTrue(app.descendants(matching: .any)["filter.summary"].exists)

        // Then only priority sessions among them.
        more.tap()
        let priority = app.buttons["Priority"].firstMatch
        XCTAssertTrue(priority.waitForExistence(timeout: timeout))
        // A press and not `tap()`: a short touch on this control can be lost, see `limitations.md`.
        priority.press(forDuration: 0.2)
        app.buttons["filters.apply"].tap()
        XCTAssertTrue(waitForDisappearance(row(app, 1027)), "a spot session leaves")
        XCTAssertTrue(row(app, 1038).exists, "the priority one stays")

        // Reset is one tap back to the default.
        app.buttons["filter.reset"].tap()
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["filter.summary"]))
        XCTAssertTrue(row(app, 1035).waitForExistence(timeout: timeout))
    }

    func test_the_sheet_keeps_its_place_and_its_choices_while_the_app_updates_behind_it() throws {
        // -ZimmerFixturePublishUnderFilters: a burst of publishes ten seconds after the sheet opens.
        let app = launch(["-ZimmerFixturePublishUnderFilters"])
        let more = app.buttons["filter.more"]
        XCTAssertTrue(more.waitForExistence(timeout: timeout))
        XCTAssertTrue(row(app, 1038).waitForExistence(timeout: timeout))
        XCTAssertFalse(row(app, 1027).exists, "Needs input only, by default")

        more.tap()
        // A switch, whose change `flip` waits to see, so a lost touch cannot pass for a lost choice.
        let failed = app.switches["filters.status.failed"]
        XCTAssertTrue(failed.waitForExistence(timeout: timeout))
        flip(failed)
        let scrolled = scrollToTheCarplayFitPicker(app)
        XCTAssertNotNil(scrolled, "the picker sits below the fold, and a swipe brings it up")
        guard let scrolled else { return }

        // Long enough to see the burst out: it starts ten seconds after the sheet opened and lasts nine.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "the app updating")], timeout: 20)

        XCTAssertEqual(pickerFrame(app)?.minY, scrolled.minY, "the form stays where it was scrolled to")
        app.buttons["filters.apply"].tap()
        XCTAssertTrue(row(app, 1027).waitForExistence(timeout: timeout), "Failed was still ticked at Apply, so the failed session joins")
        XCTAssertTrue(row(app, 1038).exists)
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureBoard", "all"] + extra
        app.launch()
        return app
    }

    /// Read in one snapshot of a fresh query, as `CarplayFitUITests.pickerFrame` says why.
    private func pickerFrame(_ app: XCUIApplication) -> CGRect? {
        let picker = app.descendants(matching: .any).matching(identifier: "filters.carplayFit").firstMatch
        guard let frame = try? picker.snapshot().frame, !frame.isEmpty else { return nil }
        return frame
    }

    private func scrollToTheCarplayFitPicker(_ app: XCUIApplication) -> CGRect? {
        for _ in 0..<6 {
            if let frame = pickerFrame(app), frame.minY > 150, app.frame.contains(CGPoint(x: frame.midX, y: frame.maxY)) { return frame }
            app.swipeUp(velocity: .slow)
        }
        return nil
    }

    private func row(_ app: XCUIApplication, _ id: Int) -> XCUIElement {
        app.descendants(matching: .any)["session.row.\(id)"]
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
