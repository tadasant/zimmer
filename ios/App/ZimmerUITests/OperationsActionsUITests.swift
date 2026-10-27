import XCTest

/// The Health page's operator actions, the Costs page's Sweep now, and the CLIs page, against
/// the `-ZimmerFixture` in-memory Zimmer. Every assertion is on state that stays on the screen:
/// an answer under its button, a count that moved, a banner that changed — never a toast.
@MainActor
final class OperationsActionsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_cleaning_up_orphans_asks_in_the_webs_words_then_the_count_moves() throws {
        let app = launch(["-ZimmerFixtureHealth"])
        XCTAssertTrue(app.descendants(matching: .any)["health.overall"].waitForExistence(timeout: timeout))
        // The process section is below the fold, and a List keeps only the rows on screen.
        let cleanup = app.buttons["health.action.cleanupProcesses"]
        XCTAssertTrue(scrollTo(app, cleanup))
        XCTAssertTrue(app.staticTexts["PID 48112"].exists, "the orphan is listed")
        cleanup.tap()
        // The web button's data-confirm, as the sheet's title; its label as the button.
        XCTAssertTrue(app.staticTexts["Are you sure you want to terminate 1 orphaned process(es)?"].waitForExistence(timeout: timeout))
        app.sheets.buttons["Clean Up Orphaned Processes"].firstMatch.tap()

        let result = app.staticTexts["health.action.cleanupProcesses.result"]
        XCTAssertTrue(waitForLabel(result, "Terminated 1 process."), "the server's receipt stays under the button")
        XCTAssertTrue(waitForDisappearance(app.staticTexts["PID 48112"]), "the report was read again: the orphan is gone")
        XCTAssertFalse(cleanup.exists, "with no orphans the button goes, as on the web page")
    }

    func test_a_cooldown_refusal_is_shown_in_place() throws {
        let app = launch(["-ZimmerFixtureHealth"])
        XCTAssertTrue(app.descendants(matching: .any)["health.overall"].waitForExistence(timeout: timeout))
        let trash = app.buttons["health.action.archiveOld"]
        XCTAssertTrue(scrollTo(app, trash))
        trash.tap()
        XCTAssertTrue(app.staticTexts["Are you sure you want to move all sessions older than 7 days to trash?"].waitForExistence(timeout: timeout))
        app.sheets.buttons["Trash Sessions Older Than 7 Days"].firstMatch.tap()
        let result = app.staticTexts["health.action.archiveOld.result"]
        XCTAssertTrue(waitForLabel(result, "Trashed 0 sessions."), "nothing in the fixture is a week old, and the page says so")

        // The second within thirty seconds: the server's refusal, under the same button.
        XCTAssertTrue(scrollTo(app, trash))
        trash.tap()
        app.sheets.buttons["Trash Sessions Older Than 7 Days"].firstMatch.tap()
        XCTAssertTrue(waitForLabel(result, "Please wait 30 seconds between actions"), "the cooldown is shown in place, not as a failure")
    }

    func test_halting_job_processing_turns_the_mode_on_and_resuming_turns_it_off() throws {
        let app = launch(["-ZimmerFixtureHealth"])
        let halt = app.buttons["health.action.enterQueueRecovery"]
        XCTAssertTrue(scrollTo(app, halt))
        halt.tap()
        XCTAssertTrue(app.sheets.buttons["Halt Job Processing"].firstMatch.waitForExistence(timeout: timeout), "the web's confirmation first")
        app.sheets.buttons["Halt Job Processing"].firstMatch.tap()

        XCTAssertTrue(app.staticTexts["ON — queues halted"].waitForExistence(timeout: timeout), "the section reads the mode on")
        // The banner heads the page, a screen above the section the app scrolled to, and a
        // List keeps only the rows on screen: reached, not waited for.
        XCTAssertTrue(scrollTo(app, app.descendants(matching: .any)["banner.queueRecovery"], searching: .up), "and the site-wide banner is up")

        // The halt re-lays out the page — the banners head it, the section grows — so Resume
        // is found afresh once the mode has flipped, back down the page, and the receipt read
        // beside it.
        let resume = app.buttons["health.action.exitQueueRecovery"]
        XCTAssertTrue(scrollTo(app, resume), "the halted section offers Resume")
        let entered = app.staticTexts["health.action.enterQueueRecovery.result"]
        XCTAssertTrue(waitForLabelContaining(entered, "Queue recovery mode is on until"))
        resume.tap()
        // Resuming collapses the section and drops the banner, which shifts the page; the app
        // brings the section back into view, and the receipt is read there, not where it was.
        let resumed = app.staticTexts["health.action.exitQueueRecovery.result"]
        if !resumed.waitForExistence(timeout: 5) { _ = scrollTo(app, resumed, searching: .up) }
        XCTAssertTrue(waitForLabel(resumed, "Job processing resumed."), "the resume's receipt, in the section")
        XCTAssertTrue(scrollTo(app, app.descendants(matching: .any)["health.queueRecovery"], searching: .up))
        XCTAssertFalse(app.staticTexts["ON — queues halted"].exists, "resumed: the mode is off")
        XCTAssertFalse(app.descendants(matching: .any)["banner.queueRecovery"].exists)
    }

    func test_sweep_now_shows_the_run_in_flight_then_the_coverage_after() throws {
        let app = launch(["-ZimmerFixtureCosts"])
        XCTAssertTrue(app.staticTexts["History backfilled"].waitForExistence(timeout: timeout))
        let sweep = app.buttons["costs.sweep"]
        XCTAssertTrue(scrollTo(app, sweep))
        sweep.tap()
        // The answer to the ask: the run, in the banner, before any re-read.
        XCTAssertTrue(app.staticTexts["Re-scanning history — 0%"].waitForExistence(timeout: timeout), "the sweep is in flight")
        // Then the page follows the run: the coverage line the web page shows once it is done.
        XCTAssertTrue(app.staticTexts["History backfilled"].waitForExistence(timeout: timeout), "the run finished")
        let swept = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Swept just now")).firstMatch
        XCTAssertTrue(swept.waitForExistence(timeout: timeout), "and the coverage says when")
    }

    func test_the_clis_screen_lists_the_tools_and_refresh_updates_the_status_line() throws {
        let app = launch(["-ZimmerFixtureClis"])
        XCTAssertTrue(app.descendants(matching: .any)["clis.tool.gh"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["2 CLI tools need attention"].exists, "the web banner's count")
        let status = app.staticTexts["clis.status"]
        XCTAssertTrue(status.label.hasPrefix("Checked "))
        XCTAssertNotEqual(status.label, "Checked just now", "the worker's check is two minutes old")

        // Each tool with its state: one signed out with its sign-in hint, one not installed with
        // its install hint, each with Copy.
        XCTAssertTrue(scrollTo(app, app.descendants(matching: .any)["clis.tool.codex"]))
        XCTAssertTrue(app.staticTexts["Not Authenticated"].firstMatch.exists)
        XCTAssertTrue(app.buttons["clis.copy.auth.codex"].exists)
        XCTAssertTrue(scrollTo(app, app.descendants(matching: .any)["clis.tool.fly"]))
        XCTAssertTrue(app.staticTexts["Not Installed"].exists)
        XCTAssertTrue(app.buttons["clis.copy.install.fly"].exists)

        app.buttons["clis.actions"].tap()
        app.buttons["Refresh"].firstMatch.tap()
        // The headline is back above the fold, where the List has it again.
        XCTAssertTrue(scrollTo(app, status, searching: .up))
        XCTAssertTrue(waitForLabel(status, "Checked just now"), "the status line follows the fresh check")

        // The More row carries the web board's badge.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let badge = app.staticTexts["more.clis.badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: timeout))
        XCTAssertEqual(badge.label, "2 CLI tools need attention")
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }

    private enum Direction { case up, down }

    /// Scroll until `element` sits between the navigation bar and the tab bar, where a tap
    /// lands on it rather than on either. A quarter-screen drag with no fling, so where the
    /// element lands is where the next check reads it: a flung swipe carries a row past the
    /// bar between one check and the next, and a List keeps only the rows on screen, so an
    /// element not in the hierarchy is looked for in `searching`'s direction. The drag starts
    /// from one of three heights in turn: a press that lands on a full-width button is
    /// swallowed by it and moves nothing (a recording shows twenty seconds of that), and the
    /// next height is clear of it.
    ///
    /// The head of the page is the one place an element can be in view and still read as
    /// above the bar: there the bar shows its large title, and its frame reaches past the top
    /// of the first row — the queue-recovery banner, on Health. An upward drag there only
    /// bounces, so an element that every start height in turn leaves where it was is at the
    /// head of a page that will not scroll further, and it is reached. A recording shows
    /// twenty-four bounces of that, the banner in plain view under the title.
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement, searching: Direction = .down) -> Bool {
        func placement() -> Direction? {
            guard element.exists, !element.frame.isEmpty else { return searching }
            let bar = app.navigationBars.firstMatch
            let top = bar.exists ? bar.frame.maxY : 0
            if element.frame.minY < top { return .up }
            if element.frame.maxY > app.frame.maxY - 100 { return .down }
            return nil
        }
        func laidOut() -> CGRect? {
            element.exists && !element.frame.isEmpty ? element.frame : nil
        }
        _ = element.waitForExistence(timeout: 2)
        let starts: [CGFloat] = [0.7, 0.6, 0.5]
        var unmoved = 0
        for attempt in 0..<24 {
            guard let direction = placement() else { return true }
            let before = direction == .up ? laidOut() : nil
            let start = starts[attempt % starts.count]
            let (from, to): (CGFloat, CGFloat) = direction == .down ? (start, start - 0.25) : (start - 0.25, start)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
            if let before, let after = laidOut(), abs(after.minY - before.minY) < 1 { unmoved += 1 } else { unmoved = 0 }
            if unmoved == starts.count { return true }
        }
        return placement() == nil
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
