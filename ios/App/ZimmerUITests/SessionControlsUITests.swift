import XCTest

/// The web UI's small controls, from the phone, against the `-ZimmerFixture` in-memory Zimmer:
/// a snooze to a time of your own, the heartbeat's interval, rename and refresh from a row's
/// long press, when a trashed session is deleted, and the confirmation before a restart that
/// takes a session over.
@MainActor
final class SessionControlsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_custom_snooze_time_from_a_row_and_from_the_session_page() throws {
        let app = launch(["-ZimmerFixtureFilter", "active"])

        // Swipe left to snooze, then *Custom…* in the dialog: the picker opens at tomorrow 9 AM.
        let sweep = row(app, 1031)
        XCTAssertTrue(sweep.waitForExistence(timeout: timeout))
        sweep.swipeLeft()
        app.buttons["Snooze"].firstMatch.tap()
        let custom = app.sheets.buttons["Custom…"].firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: timeout))
        custom.tap()
        let save = app.buttons["snooze.custom.save"]
        XCTAssertTrue(save.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["snooze.custom.picker"].exists)
        attachScreenshot(app, named: "custom-snooze")
        save.tap()
        XCTAssertTrue(waitForDisappearance(sweep), "a snoozed session leaves the board")

        app.buttons["board.menu"].tap()
        app.buttons["Snoozed & hidden"].firstMatch.tap()
        XCTAssertTrue(row(app, 1031).waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabelContaining(row(app, 1031), "Snoozed until"))

        // The session page's menu offers the same.
        app.buttons["board.menu"].tap()
        app.buttons["On board"].firstMatch.tap()
        let merge = row(app, 1038)
        XCTAssertTrue(merge.waitForExistence(timeout: timeout))
        merge.tap()
        openMenu(app, "Snooze until…")
        let pageCustom = app.buttons["Custom…"].firstMatch
        XCTAssertTrue(pageCustom.waitForExistence(timeout: timeout))
        pageCustom.tap()
        XCTAssertTrue(app.buttons["snooze.custom.save"].waitForExistence(timeout: timeout))
        app.buttons["snooze.custom.save"].tap()
        let notice = app.descendants(matching: .any)["followup.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: timeout))
        XCTAssertTrue(notice.label.hasPrefix("Snoozed until"))
    }

    func test_the_heartbeat_is_turned_on_and_its_interval_chosen() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: timeout))

        openMenu(app, "Heartbeat: off")
        tapMenuItem(app, "Turn On")
        XCTAssertTrue(app.descendants(matching: .any)["followup.notice"].waitForExistence(timeout: timeout))

        // "Beat every", from the web popout's intervals.
        openMenu(app, "Heartbeat: every 1 minute")
        let beatEvery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Beat every")).firstMatch
        XCTAssertTrue(beatEvery.waitForExistence(timeout: timeout))
        beatEvery.tap()
        tapMenuItem(app, "5 minutes")
        let notice = app.descendants(matching: .any)["followup.notice"]
        XCTAssertTrue(waitForLabelContaining(notice, "Heartbeat every 5 minutes"))

        app.buttons["detail.actions"].tap()
        XCTAssertTrue(app.buttons["Heartbeat: every 5 minutes"].firstMatch.waitForExistence(timeout: timeout), "the menu says the interval in force")
        attachScreenshot(app, named: "heartbeat")
    }

    func test_rename_and_refresh_from_a_rows_long_press() throws {
        let app = launch(["-ZimmerFixtureFilter", "active"])

        let postgres = row(app, 1035)
        XCTAssertTrue(postgres.waitForExistence(timeout: timeout))
        postgres.press(forDuration: 1.2)
        tapMenuItem(app, "Rename")
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        // The field starts with the current title; clear it and type the new one.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + "Postgres 17 on staging")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(waitForLabelContaining(postgres, "Postgres 17 on staging"), "the row shows the new title")

        // Refresh, as the card's button beside its status pill: the transcript is read again.
        let merge = row(app, 1038)
        merge.press(forDuration: 1.2)
        tapMenuItem(app, "Refresh Transcript")
        let toast = app.descendants(matching: .any)["toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: timeout))
        XCTAssertTrue(toast.label.hasPrefix("Transcript refreshed"))

        // A running session is live already, so the card offers no refresh.
        let running = row(app, 1042)
        running.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Rename"].firstMatch.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["Refresh Transcript"].firstMatch.exists)
    }

    func test_a_trashed_session_says_when_it_is_deleted() throws {
        let app = launch(["-ZimmerFixtureFilter", "archived"])
        let trashed = row(app, 1019)
        XCTAssertTrue(trashed.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabelContaining(trashed, "Deleted on"), "the row says when the trash empties it")
        attachScreenshot(app, named: "trash-expiry-row")

        trashed.tap()
        let expiry = app.descendants(matching: .any)["detail.trashexpiry"]
        XCTAssertTrue(expiry.waitForExistence(timeout: timeout))
        XCTAssertTrue(expiry.label.contains("Deleted on"))
        attachScreenshot(app, named: "trash-expiry-page")
    }

    func test_restarting_a_session_waiting_on_you_asks_first_and_a_failed_one_does_not() throws {
        let app = launch(["-ZimmerFixtureFilter", "active"])

        // Waiting on you: the web UI's takeover confirmation, in its words.
        let postgres = row(app, 1035)
        XCTAssertTrue(postgres.waitForExistence(timeout: timeout))
        postgres.press(forDuration: 1.2)
        tapMenuItem(app, "Restart Session")
        let confirm = app.sheets.buttons["Restart"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This session is paused, not failed.")).firstMatch.exists)
        attachScreenshot(app, named: "restart-confirm")
        confirm.tap()
        XCTAssertTrue(waitForLabelContaining(postgres, "Waiting"), "the turn is handed over")

        // Failed: restarted at once, as the web's button does.
        let failed = row(app, 1027)
        XCTAssertTrue(failed.waitForExistence(timeout: timeout))
        failed.press(forDuration: 1.2)
        tapMenuItem(app, "Restart Session")
        XCTAssertTrue(waitForLabelContaining(failed, "Waiting"))
        XCTAssertFalse(app.sheets.buttons["Restart"].exists, "no confirmation for a failed session")
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

    private func openMenu(_ app: XCUIApplication, _ item: String) {
        let menu = app.buttons["detail.actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()
        tapMenuItem(app, item)
    }

    private func tapMenuItem(_ app: XCUIApplication, _ item: String) {
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "the menu offers \(item)")
        button.tap()
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
