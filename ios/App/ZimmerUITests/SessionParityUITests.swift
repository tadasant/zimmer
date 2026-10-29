import XCTest

/// What the web UI's board and session page let a person do, done from the phone against
/// the `-ZimmerFixture` in-memory Zimmer: pause, snooze and restore from the list;
/// notes, restart and effort from a session's menu; and search.
@MainActor
final class SessionParityUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_pause_snooze_and_restore_from_the_list() throws {
        let app = launch()
        tapFilter(app, "active")

        // Press and hold a running session to pause it.
        let running = row(app, 1042)
        XCTAssertTrue(running.waitForExistence(timeout: timeout))
        let pause = pressForMenu(app, running, offering: "Pause Session")
        XCTAssertTrue(pause.exists, "the menu offers Pause Session")
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
        // The agent root is a chip beside the status, not a word in the metadata line.
        XCTAssertEqual(app.descendants(matching: .any)["detail.agentRoot"].label, "Agent root zimmer")
        XCTAssertFalse(app.descendants(matching: .any)["detail.metadata"].label.contains("zimmer"))
        attachScreenshot(app, named: "detail")

        // Notes, in a sheet.
        openMenu(app, "Edit Notes")
        let editor = app.textViews["edit.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        editor.tap()
        editor.typeText("Ask about the feature flag.")
        app.buttons["edit.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.notes"].waitForExistence(timeout: timeout))

        // Restart a session waiting on you: it is taken over, so it is confirmed first, as on
        // the web; then the turn is handed over, so it reads Waiting.
        openMenu(app, "Restart Session")
        let restart = app.sheets.buttons["Restart"].firstMatch
        XCTAssertTrue(restart.waitForExistence(timeout: timeout))
        restart.tap()
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
        XCTAssertTrue(row(app, 1027).waitForExistence(timeout: timeout))
        // Selecting is a state the board has to reach before a row is tapped: on a loaded
        // simulator the menu opens late, a tap fired at once misses it, and the menu then
        // stands over the row. So wait for the item, and for edit mode; once more if needed.
        let done = app.buttons["select.done"]
        for _ in 0..<2 where !done.exists {
            app.buttons["board.menu"].tap()
            let select = app.buttons["Select Sessions"].firstMatch
            if select.waitForExistence(timeout: 10) { select.tap() }
            _ = done.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(done.exists, "the board is selecting")

        // A failed session goes; one with messages queued for it is refused with the
        // server's reason, as the web UI's bulk Trash refuses it.
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

    /// Your board's rows carry "where things stand" and how current it is, as the web UI's do.
    func test_your_board_rows_carry_the_status_summary() throws {
        let app = launch(["-ZimmerFixtureView", "user"])
        let summarised = row(app, 1038)
        XCTAssertTrue(summarised.waitForExistence(timeout: timeout))
        XCTAssertTrue(summarised.label.contains("needs your go-ahead to merge"), summarised.label)
        XCTAssertTrue(summarised.label.contains("Up to date"), summarised.label)

        // Your board is ordered by dragging, as the web UI's is.
        app.buttons["board.menu"].tap()
        let reorder = app.buttons["ranked.reorder"]
        XCTAssertTrue(reorder.waitForExistence(timeout: timeout))
        XCTAssertEqual(reorder.label, "Reorder Board")
        reorder.tap()
        XCTAssertTrue(app.buttons["select.done"].waitForExistence(timeout: timeout))
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label != 'Reorder Board'"))
        XCTAssertTrue(handles.firstMatch.waitForExistence(timeout: timeout), "spot rows have drag handles")
        app.buttons["select.done"].tap()
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
        // The page opens at its newest message, so the hierarchy may be above: swipe toward it.
        for _ in 0..<6 where !child.isHittable {
            if child.frame.midY < app.frame.midY { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
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

/// Slice 2b: the Ranked view's Start now and drag-to-reorder. Every assertion is on state
/// that stays, never on a toast.
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
        let start = pressForMenu(app, sweep, offering: "Start Now")
        XCTAssertTrue(start.exists, "the menu offers Start Now")
        // The toast that confirms it is up for 2.5 seconds, less than a tap and its idle wait
        // can take on a CI runner; the row reading Running is the proof.
        start.tap()
        let running = expectation(for: NSPredicate(format: "label CONTAINS 'Running'"), evaluatedWith: sweep)
        XCTAssertEqual(XCTWaiter().wait(for: [running], timeout: timeout), .completed)
    }

    func test_the_spot_queue_is_reordered_by_dragging() throws {
        let app = launch()
        app.buttons["board.menu"].tap()
        let reorder = app.buttons["ranked.reorder"]
        XCTAssertTrue(reorder.waitForExistence(timeout: timeout))
        reorder.tap()

        // Drag the deploy key (10), fourth in the spot queue, up into second place, between the
        // sweep (50) and the CarPlay scene (30).
        let last = app.descendants(matching: .any)["session.row.1027"]
        let first = app.descendants(matching: .any)["session.row.1031"]
        let second = app.descendants(matching: .any)["session.row.1042"]
        XCTAssertTrue(last.waitForExistence(timeout: timeout))
        // Both rows on screen, or the drag has no frame to start from or land on.
        // Read from the frame: `isHittable` throws, rather than answering no, for an element
        // the list has not laid out.
        // Its top edge below the navigation bar too, so the order read after the drop is real.
        func onScreen(_ element: XCUIElement) -> Bool {
            guard element.exists, !element.frame.isEmpty else { return false }
            let bar = app.navigationBars.firstMatch
            return element.frame.minY >= (bar.exists ? bar.frame.maxY : 0)
                && app.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
        }
        var swipes = 0
        while !(onScreen(last) && onScreen(first)) && swipes < 6 {
            if last.exists && last.frame.minY > app.frame.midY { app.swipeUp() } else { app.swipeDown() }
            swipes += 1
        }
        XCTAssertTrue(onScreen(last) && onScreen(first), "both rows are on screen")
        // The handle names its row on current iOS; failing that, it is the Reorder button that
        // sits on the deploy key's row.
        let titled = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder' AND label CONTAINS 'Rotate the staging deploy key'")).firstMatch
        var handle = titled
        if !titled.waitForExistence(timeout: 10) {
            let row = last.frame
            let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'")).allElementsBoundByIndex
            handle = try XCTUnwrap(handles.first { $0.exists && row.minY <= $0.frame.midY && $0.frame.midY <= row.maxY },
                                   "a Reorder handle on the deploy key's row")
        }
        XCTAssertTrue(onScreen(handle), "the handle is on screen")
        // Let go in the upper part of the second row: past its middle, so the drop takes its
        // place, and well inside the section. A drop at the first row's top edge sits a couple
        // of points under the Priority section, and a touch that strays over it cancels the
        // move: the row springs back and no drop is ever made.
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.6, thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.25)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        // Read the order the rows settle in, not the toast: it is up for less time than the
        // drag's own idle wait can take. A refused move shows an alert instead, and its reload
        // puts the row back.
        let deadline = Date().addingTimeInterval(timeout)
        while last.frame.minY >= second.frame.minY, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertLessThan(first.frame.minY, last.frame.minY, "the sweep still heads the spot queue")
        XCTAssertLessThan(last.frame.minY, second.frame.minY, "the dropped session now sits second")
        XCTAssertFalse(app.alerts.firstMatch.exists, "the server took the move")
        app.buttons["select.done"].tap()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureFilter", "active", "-ZimmerFixtureView", "ranked"]
        app.launch()
        return app
    }
}
