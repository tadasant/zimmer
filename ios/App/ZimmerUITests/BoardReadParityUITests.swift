import XCTest

/// What the web's board rows, session header and Quick Router carry that the app did not,
/// against the `-ZimmerFixture` in-memory Zimmer: a row's genesis, agent root and precedence,
/// promote and demote and the heartbeat from a row's long press, the session page's cost, the
/// page a Quick Router start was made from, and the full form's class, precedence and Clone
/// Only. Every assertion is on state that stays, never on a toast.
@MainActor
final class BoardReadParityUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    /// Ranked: the sweep (1031, spot, rank 50, a scheduled session with no root) reads its
    /// facts on the row, and *Promote to Priority* from its long press moves it into the
    /// Priority section and starts it, as the web row's menu does.
    func test_a_ranked_row_shows_its_facts_and_promotes_from_its_menu() throws {
        let app = launch(["-ZimmerFixtureFilter", "active", "-ZimmerFixtureView", "ranked"])
        let sweep = row(app, 1031)
        XCTAssertTrue(sweep.waitForExistence(timeout: timeout))
        XCTAssertTrue(sweep.label.contains("Origin schedule"), "the genesis is on the row: \(sweep.label)")
        XCTAssertTrue(sweep.label.contains("Precedence 50"), "the precedence is on the row: \(sweep.label)")
        let merge = row(app, 1038)
        XCTAssertTrue(merge.waitForExistence(timeout: timeout))
        XCTAssertTrue(merge.label.contains("Agent root zimmer"), "the agent root is on the row: \(merge.label)")
        attachScreenshot(app, named: "ranked-row-facts")

        let promote = pressForMenu(app, sweep, offering: "Promote to Priority") { scrollBelowTheBar(app, sweep) }
        XCTAssertTrue(promote.exists, "a spot row's long press offers the promotion")
        attachScreenshot(app, named: "ranked-row-menu")
        promote.tap()
        XCTAssertTrue(waitForLabelContaining(sweep, "Priority"), "the sweep is priority: \(sweep.label)")
        XCTAssertTrue(waitForLabelContaining(sweep, "Running"), "promoting a waiting session starts it")
        let spotQueue = app.descendants(matching: .any)["section.Spot queue"]
        XCTAssertTrue(spotQueue.waitForExistence(timeout: timeout))
        XCTAssertLessThan(sweep.frame.minY, spotQueue.frame.minY, "a promoted row sits in the Priority section")

        // And back: a demotion offers itself on a priority row and lands it in the spot queue.
        let demote = pressForMenu(app, sweep, offering: "Demote to Spot") { scrollBelowTheBar(app, sweep) }
        XCTAssertTrue(demote.exists, "a priority row's long press offers the demotion")
        demote.tap()
        let demoted = expectation(for: NSPredicate(format: "NOT (label CONTAINS 'Priority')"), evaluatedWith: sweep)
        XCTAssertEqual(XCTWaiter().wait(for: [demoted], timeout: timeout), .completed, "the sweep is spot again: \(sweep.label)")
    }

    /// Last Touched draws the web's cards, whose top-right heart is the heartbeat: the row's
    /// long press turns it on, and the row then wears the heart.
    func test_a_rows_heartbeat_turns_on_from_its_menu() throws {
        let app = launch(["-ZimmerFixtureFilter", "active"])
        let merge = row(app, 1038)
        XCTAssertTrue(merge.waitForExistence(timeout: timeout))
        XCTAssertFalse(merge.label.contains("Heartbeat on"), "the fixture's heartbeat starts off")

        let turnOn = pressForMenu(app, merge, offering: "Turn Heartbeat On") { scrollBelowTheBar(app, merge) }
        XCTAssertTrue(turnOn.exists, "the row's long press offers the heartbeat")
        turnOn.tap()
        XCTAssertTrue(waitForLabelContaining(merge, "Heartbeat on"), "the row wears the heart: \(merge.label)")
        attachScreenshot(app, named: "row-heartbeat")

        let turnOff = pressForMenu(app, merge, offering: "Turn Heartbeat Off") { scrollBelowTheBar(app, merge) }
        XCTAssertTrue(turnOff.exists, "on, the menu offers off")
        turnOff.tap()
        let gone = expectation(for: NSPredicate(format: "NOT (label CONTAINS 'Heartbeat on')"), evaluatedWith: merge)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "the heart leaves the row")
    }

    /// The session page's header carries what the session has spent, beside the id, as the
    /// web header's muted figure does; a session the ledger has nothing for shows nothing.
    func test_the_session_page_shows_its_cost() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        let cost = app.descendants(matching: .any)["detail.cost"]
        XCTAssertTrue(cost.waitForExistence(timeout: timeout))
        XCTAssertTrue(cost.label.contains("17.02"), "the fixture's figure for 1038: \(cost.label)")
        attachScreenshot(app, named: "session-cost")

        app.navigationBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.buttons["filter.active"].waitForExistence(timeout: timeout))
        app.buttons["filter.active"].tap()
        let sweep = row(app, 1031)
        XCTAssertTrue(sweep.waitForExistence(timeout: timeout))
        sweep.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.status"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.descendants(matching: .any)["detail.cost"].exists, "nothing in the ledger draws nothing, not $0.00")
    }

    /// From a session's page, the Quick Router says which page it carries, and with *Open the
    /// session when it starts* off the start leaves the page where it was — the web bubble's
    /// plain *Submit* — while the session it started is on the board.
    func test_the_quick_router_from_a_session_carries_its_page_and_can_start_in_the_background() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["detail.summary"].waitForExistence(timeout: timeout))

        let button = app.buttons["quickrouter.fab"]
        XCTAssertTrue(button.waitForExistence(timeout: timeout))
        button.tap()
        let page = app.descendants(matching: .any)["quickrouter.page"]
        XCTAssertTrue(page.waitForExistence(timeout: timeout), "the sheet says what page it carries")
        XCTAssertTrue(page.label.contains("PR #1261"), "that session's title: \(page.label)")
        XCTAssertTrue(app.switches["quickrouter.parent"].exists, "and threads under it")

        let open = app.switches["quickrouter.open"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        let field = app.descendants(matching: .any)["quickrouter.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Summarise the review comments")
        attachScreenshot(app, named: "quick-router-from-session")
        app.buttons["quickrouter.start"].tap()

        XCTAssertTrue(waitForDisappearance(field), "the sheet closed")
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        XCTAssertTrue(title.label.contains("PR #1261"), "the page stayed where it was: \(title.label)")

        // The session it started is on the board, waiting, as any Quick Router start is.
        app.navigationBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.buttons["filter.active"].waitForExistence(timeout: timeout))
        app.buttons["filter.active"].tap()
        // The row is one accessibility element, so it is found by what it says.
        let started = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Summarise the review comments'")).firstMatch
        XCTAssertTrue(started.waitForExistence(timeout: timeout), "the background start is on the board")
    }

    /// The full form starts at *From its origin*, the web form's shape, and the session it makes
    /// is priority (the server's rule for the app); the precedence typed into it is on the
    /// session; and *Clone Only* makes a session with no first turn.
    func test_the_full_form_starts_from_its_origin_as_priority_and_takes_a_precedence_and_clone_only() throws {
        let app = launch(["-ZimmerFixtureNewSession"])
        let prompt = app.descendants(matching: .any)["newsession.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: timeout))

        // The class and the precedence are below the fold, under the goal.
        let classPicker = app.descendants(matching: .any)["newsession.class"]
        scrollUntilBelowTheBar(app, classPicker)
        let chosen = (classPicker.value as? String ?? "") + " " + classPicker.label
        XCTAssertTrue(chosen.contains("From its origin"), "the form starts at the web form's default: \(chosen)")
        attachScreenshot(app, named: "new-session-scheduling")
        let precedence = app.descendants(matching: .any)["newsession.precedence"]
        scrollUntilBelowTheBar(app, precedence)
        precedence.tap()
        precedence.typeText("70")
        // The prompt last, at the top: the words and the Create in the toolbar need no more scrolling.
        scrollUntilBelowTheBar(app, prompt)
        prompt.tap()
        prompt.typeText("Sweep the dependencies")
        app.buttons["newsession.create"].tap()

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        XCTAssertEqual(title.label, "Sweep the dependencies")
        XCTAssertTrue(app.staticTexts["Priority"].waitForExistence(timeout: timeout), "no class sent, and the server classes the app's create priority")
        // The precedence is the session's: its row says so. It is waiting, so it is under Active.
        app.navigationBars.buttons["Sessions"].tap()
        XCTAssertTrue(app.buttons["filter.active"].waitForExistence(timeout: timeout))
        app.buttons["filter.active"].tap()
        let created = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Sweep the dependencies'")).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabelContaining(created, "Precedence 70"), "the typed precedence is on the row: \(created.label)")

        // Clone Only: no prompt needed, and the session opens waiting on a person.
        app.buttons["newsession.open"].tap()
        let cloneOnly = app.buttons["newsession.cloneonly"]
        scrollUntilBelowTheBar(app, cloneOnly)
        XCTAssertTrue(cloneOnly.waitForExistence(timeout: timeout))
        cloneOnly.tap()
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        XCTAssertTrue(title.label.hasPrefix("Session "), "no prompt, so no title of its own: \(title.label)")
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["detail.status"], "Needs input"), "a clone with no first turn waits on a person")
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    private func row(_ app: XCUIApplication, _ id: Int) -> XCUIElement {
        app.descendants(matching: .any)["session.row.\(id)"]
    }

    /// Below the navigation bar, where a press lands on the row and not on the bar.
    private func belowTheBar(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists, !element.frame.isEmpty else { return false }
        let bar = app.navigationBars.firstMatch
        let top = bar.exists ? bar.frame.maxY : 0
        return element.frame.minY >= top && app.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.maxY))
    }

    /// A list row: swipe the list down until the row is clear of the bar.
    private func scrollBelowTheBar(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<6 where !belowTheBar(app, element) { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(belowTheBar(app, element), "the row is clear of the bar")
    }

    /// A form row anywhere in the form: a row off screen is not in the accessibility tree, so
    /// swipe up until it is; one carried under the bar is swiped back down.
    private func scrollUntilBelowTheBar(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<10 where !belowTheBar(app, element) {
            if element.exists, !element.frame.isEmpty, element.frame.minY < app.navigationBars.firstMatch.frame.maxY {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(belowTheBar(app, element), "the row is on screen and clear of the bar")
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
