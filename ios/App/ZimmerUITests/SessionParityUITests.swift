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
