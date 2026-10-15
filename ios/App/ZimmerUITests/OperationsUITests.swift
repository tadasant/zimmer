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
        // The range's fields sit above the figures, so the roots may start below the fold.
        let root = app.buttons["costs.root.zimmer"]
        XCTAssertTrue(app.staticTexts["costs.total"].waitForExistence(timeout: timeout))
        var swipes = 0
        while !(root.exists && root.isHittable) && swipes < 6 { app.swipeUp(); swipes += 1 }
        root.tap()
        XCTAssertTrue(app.descendants(matching: .any)["costs.scope"].waitForExistence(timeout: timeout), "the page says what it is narrowed to")
        XCTAssertTrue(waitForDisappearance(app.buttons["costs.root.motet"]), "only the narrowed root is left")
        let clear = app.buttons["costs.scope.clear"]
        swipes = 0
        while !(clear.exists && clear.isHittable) && swipes < 6 { app.swipeDown(); swipes += 1 }
        clear.tap()
        // The banner goes when the fleet's figures arrive; the roots are below the fold again.
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["costs.scope"]), "back to the fleet")
        let motet = app.buttons["costs.root.motet"]
        swipes = 0
        while !(motet.exists && motet.isHittable) && swipes < 6 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(motet.exists && motet.isHittable, "back to every root")

        let window = app.segmentedControls["costs.window"]
        swipes = 0
        while !(window.exists && window.isHittable) && swipes < 6 { app.swipeDown(); swipes += 1 }
        let showing = app.staticTexts["costs.showing"]
        window.buttons["30d"].tap()
        XCTAssertTrue(waitForLabel(showing, "Showing 30 days"))
        app.buttons["costs.range.apply"].tap()
        let range = expectation(for: NSPredicate(format: "label CONTAINS %@", "–"), evaluatedWith: showing)
        XCTAssertEqual(XCTWaiter().wait(for: [range], timeout: timeout), .completed, "the calendar range, from the fields the horizon filled")

        let session = app.buttons["costs.session.1042"]
        swipes = 0
        while !(session.exists && session.isHittable) && swipes < 6 { app.swipeUp(); swipes += 1 }
        session.swipeLeft()
        app.buttons["Only This"].firstMatch.tap()
        // The banner heads the page, which is still scrolled to the sessions.
        let scope = app.descendants(matching: .any)["costs.scope"]
        swipes = 0
        while !(scope.waitForExistence(timeout: 2) && scope.isHittable) && swipes < 6 { app.swipeDown(); swipes += 1 }
        XCTAssertTrue(scope.exists, "narrowed to the session")
    }

    func test_health_shows_every_section_and_the_banners_reach_the_board() throws {
        let app = launch(["-ZimmerFixtureHealth", "-ZimmerFixtureDegraded"])
        XCTAssertTrue(app.descendants(matching: .any)["health.overall"].waitForExistence(timeout: timeout))
        // The web layout's two site-wide alerts head the page while they are up.
        XCTAssertTrue(app.descendants(matching: .any)["banner.queueRecovery"].exists, "queue recovery mode is announced")
        XCTAssertTrue(app.descendants(matching: .any)["banner.egress"].exists, "degraded egress is announced")
        // Then the web page's sections, in its order, each from the report's own numbers.
        XCTAssertTrue(app.descendants(matching: .any)["health.queueRecovery"].exists)
        XCTAssertTrue(app.staticTexts["ON — queues halted"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["health.process"].exists)
        XCTAssertTrue(app.staticTexts["PID 48112"].exists, "the orphan list")
        for identifier in ["health.session", "health.system", "health.egress", "health.auth", "health.sigtermRetry", "health.apiErrorRetry",
                           "health.retryBudgets", "health.postDeployTasks", "health.cron", "health.logRetention", "health.rootData",
                           "health.warmClonePool", "health.warmProcessPool", "health.inboundEvents", "health.recentErrors"] {
            XCTAssertTrue(scrollTo(app, app.descendants(matching: .any)[identifier]), "\(identifier) is on the page")
        }
        XCTAssertTrue(app.staticTexts["reconcile_catalog_references"].exists, "the post-deploy task table names the failing task")
        XCTAssertTrue(app.staticTexts["session_health_monitor"].firstMatch.exists, "the cron key that is behind")
        // A recent failure opens its session.
        let failure = app.buttons["health.recentFailures.1027"]
        XCTAssertTrue(scrollTo(app, failure))
        failure.tap()
        XCTAssertTrue(app.navigationBars["#1027"].waitForExistence(timeout: timeout))

        // The board carries the same banners, one line each. Back pops the session the
        // failure opened; the tab alone would rely on a reselect popping the stack.
        app.navigationBars["#1027"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["banner.queueRecovery"].waitForExistence(timeout: timeout), "the board says jobs are halted")
        XCTAssertTrue(app.descendants(matching: .any)["banner.egress"].exists)
    }

    func test_the_board_has_no_banner_while_nothing_is_wrong() throws {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["session.1038"].firstMatch.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.descendants(matching: .any)["banner.queueRecovery"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["banner.egress"].exists)
    }

    func test_costs_shows_every_section_of_the_web_page() throws {
        let app = launch(["-ZimmerFixtureCosts"])
        XCTAssertTrue(app.staticTexts["costs.total"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["costs.coverage"].exists, "the ledger's coverage heads the figures")
        XCTAssertTrue(app.staticTexts["History backfilled"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["costs.tiles"].exists)
        XCTAssertTrue(app.staticTexts["API calls"].exists)
        for identifier in ["costs.unpriced", "costs.breakdown", "costs.chart", "costs.roots", "costs.features", "costs.experiments",
                           "costs.models", "costs.threadKinds", "costs.runtimes", "costs.adhoc", "costs.session.1042", "costs.burnRates"] {
            XCTAssertTrue(scrollTo(app, app.descendants(matching: .any)[identifier]), "\(identifier) is on the page")
        }
        XCTAssertTrue(app.staticTexts["Compact tool results"].exists, "an experimental setting's cohorts")
        XCTAssertTrue(app.staticTexts["cache read"].firstMatch.exists, "where the money goes, by kind of token")

        // Narrowed to a root, the fleet-only sections go.
        let root = app.buttons["costs.root.zimmer"]
        XCTAssertTrue(scrollTo(app, root))
        root.tap()
        XCTAssertTrue(app.descendants(matching: .any)["costs.scope"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["costs.burnRates"]), "burn rates are the fleet page's only")
        XCTAssertFalse(app.descendants(matching: .any)["costs.experiments"].exists)
    }

    func test_run_now_asks_for_the_templates_variables_and_the_session_carries_them() throws {
        let app = launch(["-ZimmerFixtureTrigger", "7"])
        XCTAssertTrue(app.navigationBars["Slack thread triage"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["trigger.detail.schedulingClass"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["trigger.detail.catalog_hooks"].exists, "the hooks chips")

        app.buttons["trigger.detail.actions"].tap()
        app.buttons["Run Now"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["trigger.run.sheet"].waitForExistence(timeout: timeout), "a template with variables asks for them")
        let text = app.textViews["trigger.run.text"].firstMatch.exists ? app.textViews["trigger.run.text"].firstMatch : app.textFields["trigger.run.text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: timeout))
        text.tap()
        text.typeText("Review PR 42")
        let author = app.textFields["trigger.run.author"]
        author.tap()
        author.typeText("Jane")
        app.buttons["trigger.run.submit"].tap()

        // The session it started opens, and its title is the template with the values in it:
        // the state the run left behind, not a toast.
        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        let carried = expectation(for: NSPredicate(format: "label CONTAINS %@", "Review PR 42"), evaluatedWith: title)
        XCTAssertEqual(XCTWaiter().wait(for: [carried], timeout: timeout), .completed, "the variables reached the prompt")
    }

    func test_the_trigger_page_shows_the_catalog_chips_and_the_windows() throws {
        let app = launch(["-ZimmerFixtureTrigger", "5"])
        XCTAssertTrue(app.navigationBars["Nightly dependency sweep"].waitForExistence(timeout: timeout))
        for identifier in ["trigger.detail.skipPending", "trigger.detail.coalescing", "trigger.detail.missedFires", "trigger.detail.schedulingClass",
                           "trigger.detail.precedence", "trigger.detail.mcp_servers", "trigger.detail.catalog_skills", "trigger.detail.catalog_plugins"] {
            XCTAssertTrue(scrollTo(app, app.descendants(matching: .any)[identifier]), "\(identifier) is on the page")
        }
        XCTAssertTrue(app.staticTexts["linear (not in catalog)"].exists, "a name the catalog no longer resolves is flagged")
        XCTAssertTrue(app.staticTexts["spot"].firstMatch.exists, "the effective scheduling class")
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }

    /// Scroll until `element` sits below the navigation bar, where a tap lands on it rather
    /// than on the bar; false if six swipes do not find it.
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        func belowTheBar() -> Bool {
            guard element.exists, !element.frame.isEmpty else { return false }
            let bar = app.navigationBars.firstMatch
            let top = bar.exists ? bar.frame.maxY : 0
            return element.frame.minY >= top && element.frame.minY < app.frame.maxY
        }
        for _ in 0..<10 where !belowTheBar() { app.swipeUp() }
        return belowTheBar()
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
