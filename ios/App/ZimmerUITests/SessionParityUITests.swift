import XCTest

/// What the web UI's board and session page let a person do, done from the phone against
/// the `-ZimmerFixture` in-memory Zimmer: star, pause, snooze and restore from the list;
/// notes, restart and effort from a session's menu; and search.
@MainActor
final class SessionParityUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_star_pause_snooze_and_restore_from_the_list() throws {
        let app = launch()
        tapFilter(app, "active")

        // Swipe right to star: the session's page then offers to remove it from favourites.
        let postgres = row(app, 1035)
        XCTAssertTrue(postgres.waitForExistence(timeout: timeout))
        postgres.swipeRight()
        // A long enough swipe stars it outright; a shorter one leaves the button to tap.
        let favorite = app.buttons["Favorite"].firstMatch
        if favorite.waitForExistence(timeout: 2) { favorite.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForExistence(timeout: timeout))
        postgres.tap()
        let star = app.buttons["detail.favorite"]
        XCTAssertTrue(star.waitForExistence(timeout: timeout))
        XCTAssertEqual(star.label, "Remove from Favorites")
        app.navigationBars.buttons["Sessions"].tap()

        // Press and hold a running session to pause it.
        let running = row(app, 1042)
        XCTAssertTrue(running.waitForExistence(timeout: timeout))
        running.press(forDuration: 1.2)
        let pause = app.buttons["Pause Session"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: timeout))
        pause.tap()
        XCTAssertTrue(waitForLabelContaining(running, "Needs input"), "a paused session comes to rest waiting on you")

        // Swipe left to snooze: it leaves the board, and the board's filter finds it.
        let sweep = row(app, 1031)
        XCTAssertTrue(sweep.waitForExistence(timeout: timeout))
        sweep.swipeLeft()
        app.buttons["Snooze"].firstMatch.tap()
        let tomorrow = app.buttons["Tomorrow"].firstMatch
        XCTAssertTrue(tomorrow.waitForExistence(timeout: timeout))
        tomorrow.tap()
        XCTAssertTrue(waitForDisappearance(sweep), "a snoozed session leaves the board")
        XCTAssertFalse(row(app, 1029).exists, "the fixture's snoozed session is off the board too")

        app.buttons["board.menu"].tap()
        app.buttons["Snoozed & hidden"].firstMatch.tap()
        XCTAssertTrue(row(app, 1031).waitForExistence(timeout: timeout))
        XCTAssertTrue(row(app, 1029).exists)
        XCTAssertFalse(row(app, 1042).exists, "sessions on the board are not in Snoozed & hidden")
        attachScreenshot(app, named: "snoozed-and-hidden")

        // Restore from the trash with a swipe.
        app.buttons["board.menu"].tap()
        app.buttons["Both"].firstMatch.tap()
        tapFilter(app, "archived")
        let trashed = row(app, 1019)
        XCTAssertTrue(trashed.waitForExistence(timeout: timeout))
        trashed.swipeLeft()
        app.buttons["Restore"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(trashed), "a restored session leaves the trash")
    }

    func test_notes_restart_and_effort_from_the_session_menu() throws {
        let app = launch()
        let merge = row(app, 1038)
        XCTAssertTrue(merge.waitForExistence(timeout: timeout))
        merge.tap()

        // What the web UI's metadata block and PR button show.
        XCTAssertTrue(app.descendants(matching: .any)["detail.goal"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["detail.pr.#1261"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["detail.metadata"].label.contains("effort high"))
        attachScreenshot(app, named: "detail")

        // Notes, in a sheet.
        openMenu(app, "Edit Notes")
        let editor = app.textViews["edit.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        editor.tap()
        editor.typeText("Ask about the feature flag.")
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.notes"].waitForExistence(timeout: timeout))

        // Restart a session waiting on you: the turn is handed over, so it reads Waiting.
        openMenu(app, "Restart Session")
        XCTAssertTrue(waitForLabel(app.staticTexts["detail.status"], "Waiting"))

        // Effort, from the levels the session's model accepts.
        openMenu(app, "Effort: high")
        app.buttons["max"].firstMatch.tap()
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["detail.metadata"], "effort max"))
    }

    func test_search_finds_sessions_by_title() throws {
        let app = launch()
        tapFilter(app, "active")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: timeout))
        search.tap()
        search.typeText("postgres")
        XCTAssertTrue(waitForDisappearance(row(app, 1042)), "a session whose title does not match is not shown")
        XCTAssertTrue(row(app, 1035).exists)
        attachScreenshot(app, named: "search")
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"]
        app.launch()
        return app
    }

    private func row(_ app: XCUIApplication, _ id: Int) -> XCUIElement {
        app.descendants(matching: .any)["session.row.\(id)"]
    }

    private func tapFilter(_ app: XCUIApplication, _ name: String) {
        let chip = app.buttons["filter.\(name)"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))
        chip.tap()
    }

    private func openMenu(_ app: XCUIApplication, _ item: String) {
        let menu = app.buttons["detail.actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "the session menu offers \(item)")
        button.tap()
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
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

/// Slice 2: the board views, selecting several to trash, Refresh All, the hierarchy and the transcript.
@MainActor
final class BoardViewUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_ranked_view_splits_priority_from_the_spot_queue_in_rank_order() throws {
        let app = launch(["-ZimmerFixtureFilter", "active"])
        app.buttons["board.menu"].tap()
        app.buttons["Ranked"].firstMatch.tap()

        XCTAssertTrue(app.descendants(matching: .any)["section.Priority"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["section.Spot queue"].exists)
        // Spot queue by precedence: the sweep (50) above CarPlay (30) above Postgres (20).
        let sweep = row(app, 1031), carplay = row(app, 1042), postgres = row(app, 1035)
        XCTAssertTrue(sweep.waitForExistence(timeout: timeout))
        XCTAssertLessThan(sweep.frame.minY, carplay.frame.minY)
        XCTAssertLessThan(carplay.frame.minY, postgres.frame.minY)
        XCTAssertLessThan(row(app, 1038).frame.minY, sweep.frame.minY, "the priority session is above the whole spot queue")
    }

    func test_select_several_and_trash_them_with_refusals_reported() throws {
        let app = launch(["-ZimmerFixtureFilter", "active"])
        app.buttons["board.menu"].tap()
        app.buttons["Select Sessions"].firstMatch.tap()

        // A failed session goes; a running one is refused with the server's reason.
        let failed = row(app, 1027), running = row(app, 1042)
        XCTAssertTrue(failed.waitForExistence(timeout: timeout))
        failed.tap()
        running.tap()
        app.buttons["select.trash"].tap()
        let confirm = app.buttons["Trash 2"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()

        XCTAssertTrue(app.descendants(matching: .any)["error.banner"].waitForExistence(timeout: timeout), "the refusal is shown")
        XCTAssertTrue(waitForDisappearance(failed))
        XCTAssertTrue(running.exists, "the refused session stays")
    }

    func test_refresh_all_reports_what_it_did() throws {
        let app = launch(["-ZimmerFixtureFilter", "active"])
        app.buttons["board.menu"].tap()
        app.buttons["Refresh All"].firstMatch.tap()
        let confirm = app.buttons["Refresh All Now"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForExistence(timeout: timeout))
    }

    func test_the_hierarchy_opens_a_related_session() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        let child = app.descendants(matching: .any)["hierarchy.node.1042"]
        XCTAssertTrue(child.waitForExistence(timeout: timeout))
        for _ in 0..<6 where !child.isHittable {
            app.swipeUp(velocity: .slow)
        }
        child.tap()
        XCTAssertTrue(app.navigationBars["#1042"].waitForExistence(timeout: timeout), "the spawned session opens")
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    private func row(_ app: XCUIApplication, _ id: Int) -> XCUIElement {
        app.descendants(matching: .any)["session.row.\(id)"]
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}

/// Slice 2b: the Ranked view's Start now and drag-to-reorder.
@MainActor
final class RankedUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_start_now_takes_a_waiting_sessions_turn() throws {
        let app = launch()
        let sweep = app.descendants(matching: .any)["session.row.1031"]
        XCTAssertTrue(sweep.waitForExistence(timeout: timeout))
        sweep.press(forDuration: 1.2)
        let start = app.buttons["Start Now"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: timeout))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForExistence(timeout: timeout))
        let running = expectation(for: NSPredicate(format: "label CONTAINS 'Running'"), evaluatedWith: sweep)
        XCTAssertEqual(XCTWaiter().wait(for: [running], timeout: timeout), .completed)
    }

    func test_the_spot_queue_is_reordered_by_dragging() throws {
        let app = launch()
        app.buttons["board.menu"].tap()
        let reorder = app.buttons["ranked.reorder"]
        XCTAssertTrue(reorder.waitForExistence(timeout: timeout))
        reorder.tap()

        // Drag the last of the spot queue (the deploy key, 10) above the first (the sweep, 50).
        let last = app.descendants(matching: .any)["session.row.1027"]
        let first = app.descendants(matching: .any)["session.row.1031"]
        XCTAssertTrue(last.waitForExistence(timeout: timeout))
        // The handle names its row on current iOS; failing that, it is the spot queue's fourth.
        let titled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'Rotate the staging deploy key'")).firstMatch
        let handle = titled.waitForExistence(timeout: 5) ? titled : app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'")).element(boundBy: 3)
        XCTAssertTrue(handle.waitForExistence(timeout: timeout))
        // Let go near the top edge of the first row, so the drop lands above it, not below.
        handle.press(forDuration: 0.6, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.05)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        // The toast comes after the reload, so the new order is on screen by then.
        XCTAssertTrue(app.descendants(matching: .any)["toast"].waitForExistence(timeout: timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while last.frame.minY >= first.frame.minY, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertLessThan(last.frame.minY, first.frame.minY, "the dropped session now heads the spot queue")
        app.buttons["select.done"].tap()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureFilter", "active", "-ZimmerFixtureView", "ranked"]
        app.launch()
        return app
    }
}
