import XCTest

/// Slice 5: the tab bar — the inbox, triggers, and costs and health under More — against the
/// `-ZimmerFixture` in-memory Zimmer.
@MainActor
final class OperationsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_notification_opens_its_session_on_the_sessions_tab() throws {
        let app = launch()
        app.tabBars.buttons["Inbox"].tap()
        let notification = app.buttons["inbox.91"]
        XCTAssertTrue(notification.waitForExistence(timeout: timeout))
        notification.tap()
        XCTAssertTrue(app.navigationBars["#1038"].waitForExistence(timeout: timeout), "the session it is about opens")
        XCTAssertTrue(app.tabBars.buttons["Sessions"].isSelected)
    }

    func test_a_trigger_is_turned_on_and_invoked() throws {
        let app = launch()
        app.tabBars.buttons["Triggers"].tap()
        let toggle = app.switches["trigger.toggle.6"]
        XCTAssertTrue(toggle.waitForExistence(timeout: timeout))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        XCTAssertTrue(waitForValue(toggle, "1"), "the slack trigger is on")

        let nightly = app.descendants(matching: .any)["trigger.5"].firstMatch
        nightly.swipeLeft()
        app.buttons["Invoke"].firstMatch.tap()
        let confirm = app.sheets.buttons["Invoke Nightly dependency sweep"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: timeout), "the session it started opens")
    }

    func test_costs_and_health_read_from_more() throws {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        app.descendants(matching: .any)["more.costs"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["costs.total"].waitForExistence(timeout: timeout))
        app.navigationBars.buttons["More"].tap()
        app.descendants(matching: .any)["more.health"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["health.overall"].waitForExistence(timeout: timeout))
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"]
        app.launch()
        return app
    }

    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }
}
