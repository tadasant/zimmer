import XCTest

/// Slice 5: the tab bar — the inbox, triggers, and costs and health under More — and a
/// trigger's page and the Costs drilldown, against the `-ZimmerFixture` in-memory Zimmer.
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

    func test_a_trigger_opens_its_page_where_it_is_turned_off_and_invoked() throws {
        let app = launch()
        app.tabBars.buttons["Triggers"].tap()
        let open = app.buttons["trigger.open.5"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        XCTAssertTrue(app.navigationBars["Nightly dependency sweep"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["trigger.detail.enqueue"].waitForExistence(timeout: timeout),
                      "the re-use settings are on the page")
        XCTAssertTrue(app.descendants(matching: .any)["trigger.detail.lastSession"].exists, "the session it last started is a tap away")

        // A labelled switch: tap the switch itself, at the row's trailing edge.
        let toggle = app.switches["trigger.detail.toggle"]
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue(toggle, "0"), "the trigger is off")

        let actions = app.buttons["trigger.detail.actions"]
        actions.tap()
        app.buttons["Invoke Now"].firstMatch.tap()
        let confirm = app.sheets.buttons["Invoke Nightly dependency sweep"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: timeout), "the session it started opens")
    }

    func test_costs_narrow_to_a_root_and_a_session_and_read_a_calendar_range() throws {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        app.descendants(matching: .any)["more.costs"].firstMatch.tap()
        let root = app.buttons["costs.root.zimmer"]
        XCTAssertTrue(root.waitForExistence(timeout: timeout))
        root.tap()
        XCTAssertTrue(app.descendants(matching: .any)["costs.scope"].waitForExistence(timeout: timeout), "the page says what it is narrowed to")
        XCTAssertTrue(waitForDisappearance(app.buttons["costs.root.motet"]), "only the narrowed root is left")
        app.buttons["costs.scope.clear"].tap()
        XCTAssertTrue(app.buttons["costs.root.motet"].waitForExistence(timeout: timeout), "back to every root")

        let showing = app.staticTexts["costs.showing"]
        app.segmentedControls["costs.window"].buttons["30d"].tap()
        XCTAssertTrue(waitForLabel(showing, "Showing 30 days"))
        app.buttons["costs.range.apply"].tap()
        let range = expectation(for: NSPredicate(format: "label CONTAINS %@", "–"), evaluatedWith: showing)
        XCTAssertEqual(XCTWaiter().wait(for: [range], timeout: timeout), .completed, "the calendar range, from the fields the horizon filled")

        let session = app.buttons["costs.session.1042"]
        for _ in 0..<4 where !session.isHittable { app.swipeUp() }
        session.swipeLeft()
        app.buttons["Only This"].firstMatch.tap()
        // The banner heads the page, which is still scrolled to the sessions.
        let scope = app.descendants(matching: .any)["costs.scope"]
        for _ in 0..<4 where !scope.waitForExistence(timeout: 2) { app.swipeDown() }
        XCTAssertTrue(scope.exists, "narrowed to the session")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"]
        app.launch()
        return app
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }
}
