import XCTest

/// Slice 5: the tab bar — the inbox, triggers, and costs and health under More — and a
/// trigger's page and the Costs drilldown, against the `-ZimmerFixture` in-memory Zimmer.
@MainActor
final class OperationsUITests: XCTestCase {
    private let timeout: TimeInterval = 30

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
        app.buttons["Run Now"].firstMatch.tap()
        let confirm = app.sheets.buttons["Invoke Nightly dependency sweep"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: timeout), "the session it started opens")
    }

    func test_costs_narrow_to_a_root_and_a_session_and_read_a_calendar_range() throws {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        app.descendants(matching: .any)["more.costs"].firstMatch.tap()
        // The coverage, tiles and chart sit above the roots, so they start below the fold.
        let root = app.buttons["costs.root.zimmer"]
        XCTAssertTrue(app.staticTexts["costs.total"].waitForExistence(timeout: timeout))
        XCTAssertTrue(reach(app, "costs.root.zimmer", whole: true), "the zimmer root is on the page")
        root.tap()
        // The narrowed figures arrive where the page is; the banner that names the scope heads
        // the page, which a lazy List lays out only once scrolled back up to.
        XCTAssertTrue(waitForDisappearance(app.buttons["costs.root.motet"]), "only the narrowed root is left")
        let clear = app.buttons["costs.scope.clear"]
        XCTAssertTrue(reach(app, "costs.scope.clear", whole: true, searching: .up), "the page says what it is narrowed to")
        XCTAssertTrue(app.descendants(matching: .any)["costs.scope"].exists)
        clear.tap()
        // The banner goes when the fleet's figures arrive; the roots are below the fold again.
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["costs.scope"]), "back to the fleet")
        let motet = app.buttons["costs.root.motet"]
        XCTAssertTrue(reach(app, "costs.root.motet", whole: true), "back to every root")
        XCTAssertTrue(motet.exists)

        let window = app.segmentedControls["costs.window"]
        XCTAssertTrue(reach(app, "costs.window", whole: true, searching: .up), "the window picker heads the page")
        let showing = app.staticTexts["costs.showing"]
        window.buttons["30d"].tap()
        XCTAssertTrue(waitForLabel(showing, "Showing 30 days"))
        app.buttons["costs.range.apply"].tap()
        let range = expectation(for: NSPredicate(format: "label CONTAINS %@", "–"), evaluatedWith: showing)
        XCTAssertEqual(XCTWaiter().wait(for: [range], timeout: timeout), .completed, "the calendar range, from the fields the horizon filled")

        let session = app.buttons["costs.session.1042"]
        XCTAssertTrue(reach(app, "costs.session.1042", whole: true), "the sessions are far down the page")
        session.swipeLeft()
        app.buttons["Only This"].firstMatch.tap()
        // The other session goes where the page is; the banner heads the page, laid out once
        // scrolled back up to.
        XCTAssertTrue(waitForDisappearance(app.buttons["costs.session.1038"]), "narrowed to the one session")
        XCTAssertTrue(reach(app, "costs.scope.clear", whole: true, searching: .up), "the page says which session")
        XCTAssertTrue(app.descendants(matching: .any)["costs.scope"].exists)
    }

    func test_health_shows_every_section_and_the_banners_reach_the_board() throws {
        let app = launch(["-ZimmerFixtureHealth", "-ZimmerFixtureDegraded"])
        XCTAssertTrue(app.descendants(matching: .any)["health.overall"].waitForExistence(timeout: timeout))
        // The web layout's two site-wide alerts head the page while they are up.
        XCTAssertTrue(app.descendants(matching: .any)["banner.queueRecovery"].exists, "queue recovery mode is announced")
        XCTAssertTrue(app.descendants(matching: .any)["banner.egress"].exists, "degraded egress is announced")
        // Then the web page's sections, in its order, each from the report's own numbers.
        XCTAssertTrue(reach(app, "health.queueRecovery"))
        XCTAssertTrue(app.staticTexts["ON — queues halted"].exists)
        // A List lays out lazily: a section below the fold is not in the hierarchy until scrolled to.
        XCTAssertTrue(reach(app, "health.process"))
        XCTAssertTrue(app.staticTexts["PID 48112"].exists, "the orphan list")
        // Each section's own words are checked while it is laid out: a lazy List drops a
        // section once it is scrolled past.
        let sections: [(String, String?)] = [
            ("health.session", nil), ("health.system", nil), ("health.egress", nil), ("health.auth", nil), ("health.sigtermRetry", nil),
            ("health.apiErrorRetry", nil), ("health.retryBudgets", nil), ("health.postDeployTasks", "reconcile_catalog_references"),
            ("health.cron", "session_health_monitor"), ("health.logRetention", nil), ("health.rootData", nil), ("health.warmClonePool", nil),
            ("health.warmProcessPool", nil), ("health.inboundEvents", nil), ("health.recentErrors", nil),
        ]
        for (identifier, text) in sections {
            XCTAssertTrue(reach(app, identifier), "\(identifier) is on the page")
            if let text { XCTAssertTrue(app.staticTexts[text].firstMatch.exists, "\(identifier) names \(text)") }
        }
        // A recent failure opens its session. Recent Failures is above Recent Errors, where
        // the walk ended: searching down from the foot of the page spent twenty steps, two
        // minutes and more, before turning back, and took the test past its five minutes.
        let failure = app.buttons["health.recentFailures.1027"]
        XCTAssertTrue(reach(app, "health.recentFailures.1027", whole: true, searching: .up))
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
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].firstMatch.waitForExistence(timeout: timeout))
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
        // Each section's own words are checked while it is laid out: a lazy List drops a
        // section once it is scrolled past.
        let sections: [(String, String?)] = [
            ("costs.unpriced", nil), ("costs.breakdown", "cache read"), ("costs.chart", nil), ("costs.roots", nil), ("costs.features", nil),
            ("costs.experiments", "Compact tool results"), ("costs.models", nil), ("costs.threadKinds", nil), ("costs.runtimes", nil),
            ("costs.adhoc", nil), ("costs.session.1042", nil), ("costs.burnRates", nil),
        ]
        for (identifier, text) in sections {
            XCTAssertTrue(reach(app, identifier), "\(identifier) is on the page")
            if let text { XCTAssertTrue(app.staticTexts[text].firstMatch.exists, "\(identifier) shows \(text)") }
        }

        // Narrowed to a root, the fleet-only sections go: the burn rates at the foot, which
        // are laid out where the page is, and the banner at its head once scrolled back to.
        let root = app.buttons["costs.root.zimmer"]
        XCTAssertTrue(reach(app, "costs.root.zimmer", whole: true, searching: .up), "the roots are above the burn rates the walk ended on")
        root.tap()
        XCTAssertTrue(waitForDisappearance(app.buttons["costs.root.motet"]), "only the narrowed root is left")
        XCTAssertTrue(reach(app, "costs.scope.clear", whole: true, searching: .up), "the page says what it is narrowed to")
        XCTAssertTrue(app.descendants(matching: .any)["costs.scope"].exists)
        XCTAssertTrue(reach(app, "costs.session.1042"), "the narrowed page still lists its session")
        XCTAssertFalse(app.descendants(matching: .any)["costs.experiments"].exists, "experiments are the fleet page's only")
        XCTAssertFalse(app.descendants(matching: .any)["costs.burnRates"].exists, "burn rates are the fleet page's only")
    }

    func test_run_now_asks_for_the_templates_variables_and_the_session_carries_them() throws {
        let app = launch(["-ZimmerFixtureTrigger", "7"])
        XCTAssertTrue(app.navigationBars["Slack thread triage"].waitForExistence(timeout: timeout))
        XCTAssertTrue(reach(app, "trigger.detail.schedulingClass"))
        XCTAssertTrue(reach(app, "trigger.detail.catalog_hooks"), "the hooks chips")

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
        // Each row's own words are checked as it is reached, never after moving on.
        let rows: [(String, String?)] = [
            ("trigger.detail.skipPending", nil), ("trigger.detail.coalescing", nil), ("trigger.detail.missedFires", nil),
            ("trigger.detail.schedulingClass", "spot"), ("trigger.detail.precedence", nil),
            ("trigger.detail.mcp_servers", "linear (not in catalog)"), ("trigger.detail.catalog_skills", nil), ("trigger.detail.catalog_plugins", nil),
        ]
        for (identifier, text) in rows {
            XCTAssertTrue(reach(app, identifier), "\(identifier) is on the page")
            if let text { XCTAssertTrue(app.staticTexts[text].firstMatch.exists, "\(identifier) shows \(text)") }
        }
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }

    /// Bring the element named `identifier` onto the screen — below the navigation bar, above
    /// the tab bar, and whole when it is about to be tapped — by dragging less than a screen
    /// at a time and holding, so there is no fling: on a loaded simulator a fling carries a
    /// short section past the screen in one go, and a lazy List never lays it out. Twenty steps
    /// in `searching`'s direction, then twenty back — a caller at the foot of the page looking
    /// for its head says `.up`, or the walk spends its steps parked at the bottom — giving up
    /// after forty; done the moment the element is on screen (a `where` clause on the loop
    /// would skip the drag and keep checking, thirty times three seconds for every section a
    /// walk reaches). Once the element is laid out off the screen it says which way it is, and
    /// the walk goes that way whatever its phase: a drag can coast further than its length, and
    /// on a loaded simulator one carried the Costs page's experiments header from under the tab
    /// bar to above the navigation bar, after which the walk spent its other downward steps,
    /// two minutes, walking away from it. The first match, since a container's identifier can
    /// reach more than one element.
    private enum Direction { case up, down }

    private func reach(_ app: XCUIApplication, _ identifier: String, whole: Bool = false, searching: Direction = .down) -> Bool {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        // The bars do not move while the page scrolls: read once, not five queries a step.
        let bar = app.navigationBars.firstMatch
        let top = bar.exists ? bar.frame.maxY : 0
        let tabBar = app.tabBars.firstMatch
        let bottom = tabBar.exists ? tabBar.frame.minY : app.frame.maxY
        func laidOut() -> CGRect? {
            guard element.waitForExistence(timeout: 1), !element.frame.isEmpty else { return nil }
            return element.frame
        }
        func onScreen(_ frame: CGRect) -> Bool {
            frame.minY >= top && (whole ? frame.maxY <= bottom : frame.minY < bottom)
        }
        for step in 0..<40 {
            let frame = laidOut()
            if let frame, onScreen(frame) { return true }
            // Above the screen, back up to it; below, or not wholly above the tab bar, on down.
            let down = frame.map { $0.minY >= top } ?? ((step < 20) == (searching == .down))
            // Where a drag starts alternates between two heights, a quarter screen apart, and
            // where it ends does not: a control that takes a drag for itself — the spend-by-day
            // chart, whose selection follows the finger — would otherwise take every step, and
            // the page would never move. That holds whichever way the walk goes: an upward walk
            // that always started a fifth of the way down, with the chart parked there, selected
            // a bar forty times over and never scrolled. The chart is shorter than the quarter
            // screen between the two starts, so it can take at most every other step.
            // The top of a drag is at least a fifth of the way down, under the navigation bar
            // and the Staging banner (a press on the bar moves nothing), so a drag is most of a
            // screen and never under two fifths of one: a step is seconds whatever its length,
            // and the Costs page is a dozen screens.
            // No section can pass the screen unseen — that would take more than a screen of
            // travel — and the hold at the end keeps it from flinging. And left of centre,
            // clear of the Quick Router button at the bottom right.
            let low = 0.88, high = 0.2
            let start = down ? (step.isMultiple(of: 2) ? low : 0.63) : (step.isMultiple(of: 2) ? high : 0.45)
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: start))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: down ? high : low))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
        }
        return laidOut().map(onScreen) ?? false
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
