import UIKit
import XCTest

/// The web UI's small controls, from the phone, against the `-ZimmerFixture` in-memory Zimmer:
/// a snooze to a time of your own, the heartbeat's interval, rename and refresh from a row's
/// long press, when a trashed session's restore window closes, the confirmation before a
/// restart that takes a session over, and pasting an image into the composer.
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
        // By its words: an earlier toast can still be on screen when this one arrives.
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["followup.notice"], "Snoozed until"))
    }

    func test_the_heartbeat_is_turned_on_and_its_interval_chosen() throws {
        // 1035, not 1038: the session menu is taller than the screen, and XCUITest finds only
        // the rows laid out on it. 1038's Merge section and View PR row push the heartbeat item
        // below the fold; 1035 has no PR, so the item is on screen.
        let app = launch(["-ZimmerFixtureOpenSession", "1035"])
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
        openRowMenu(app, postgres, "Rename")
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        // The field opens focused with the cursor after the current title: delete it and type
        // the new one, without a tap that would move the cursor.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 60) + "Postgres 17 on staging")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(waitForLabelContaining(postgres, "Postgres 17 on staging"), "the row shows the new title")

        // Refresh, as the card's button beside its status pill: the transcript is read again.
        let merge = row(app, 1038)
        openRowMenu(app, merge, "Refresh Transcript")
        // By its words: the "Renamed" toast can still be on screen.
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["toast"], "Transcript refreshed"))

        // A running session is live already, so the card offers no refresh.
        let running = row(app, 1042)
        XCTAssertTrue(pressForMenu(app, running, offering: "Rename").exists, "the menu opens")
        XCTAssertFalse(app.buttons["Refresh Transcript"].firstMatch.exists)
    }

    func test_a_trashed_session_says_when_its_restore_window_closes() throws {
        let app = launch(["-ZimmerFixtureFilter", "archived"])
        let trashed = row(app, 1019)
        XCTAssertTrue(trashed.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabelContaining(trashed, "Expires"), "the row says when what is held for a restore is deleted")
        attachScreenshot(app, named: "trash-expiry-row")

        trashed.tap()
        let expiry = app.descendants(matching: .any)["detail.trashexpiry"].firstMatch
        XCTAssertTrue(expiry.waitForExistence(timeout: timeout))
        XCTAssertTrue(expiry.label.contains("Expires"))
        attachScreenshot(app, named: "trash-expiry-page")
    }

    func test_restarting_a_session_waiting_on_you_asks_first_and_a_failed_one_does_not() throws {
        let app = launch(["-ZimmerFixtureFilter", "active"])

        // Waiting on you: the web UI's takeover confirmation, in its words.
        let postgres = row(app, 1035)
        XCTAssertTrue(postgres.waitForExistence(timeout: timeout))
        openRowMenu(app, postgres, "Restart Session")
        let confirm = app.sheets.buttons["Restart"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This session is paused, not failed.")).firstMatch.exists)
        attachScreenshot(app, named: "restart-confirm")
        confirm.tap()
        XCTAssertTrue(waitForLabelContaining(postgres, "Waiting"), "the turn is handed over")

        // Failed: restarted at once, as the web's button does.
        let failed = row(app, 1027)
        XCTAssertTrue(failed.waitForExistence(timeout: timeout))
        openRowMenu(app, failed, "Restart Session")
        XCTAssertTrue(waitForLabelContaining(failed, "Waiting"))
        XCTAssertFalse(app.sheets.buttons["Restart"].exists, "no confirmation for a failed session")
    }

    /// The web composer takes a pasted image. The test runner puts one on the pasteboard, and
    /// iOS asks whether Zimmer may paste from another app: that prompt is answered *Allow Paste*
    /// wherever it is drawn (SpringBoard, or the app's own window on some runtimes).
    func test_an_image_on_the_clipboard_is_pasted_into_the_composer() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        UIPasteboard.general.image = image

        let allowPaste = addUIInterruptionMonitor(withDescription: "Allow Paste") { alert in
            let allow = alert.buttons["Allow Paste"]
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
        defer { removeUIInterruptionMonitor(allowPaste) }

        let app = launch(["-ZimmerFixtureOpenSession", "1035"])
        let attach = app.buttons["composer.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: timeout))
        attach.tap()
        tapMenuItem(app, "Paste Image")

        // The app's main thread waits on the answer, so SpringBoard is asked first: a query of
        // the app while the prompt is up times out as a failed test, not as a false. A tap on
        // *Allow Paste* does not always take, so it is tapped again until the prompt is gone,
        // within a deadline that leaves room for a few retries.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let springboardAllow = springboard.alerts.buttons["Allow Paste"].firstMatch
        let deadline = Date().addingTimeInterval(timeout * 2)
        while Date() < deadline {
            if springboardAllow.exists {
                // Hittable, so a prompt that went away late is not tapped after it has gone.
                if springboardAllow.isHittable { springboardAllow.tap() }
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: springboardAllow)
                if XCTWaiter().wait(for: [gone], timeout: 5) == .completed { break }
                continue
            }
            let fromApp = app.alerts.buttons["Allow Paste"].firstMatch
            if fromApp.exists { fromApp.tap(); break }
            let chip = pastedChip(app)
            if chip.exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(springboardAllow.exists, "SpringBoard's Allow Paste prompt never went away")

        XCTAssertTrue(pastedChip(app).waitForExistence(timeout: timeout), "the pasted image is attached, as a library photo is")
        attachScreenshot(app, named: "pasted-image")
    }

    // MARK: - Helpers

    private func pastedChip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer.attachment.Pasted image")).firstMatch
    }

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

    /// A row's long press, then `item` in its menu.
    private func openRowMenu(_ app: XCUIApplication, _ row: XCUIElement, _ item: String) {
        let button = pressForMenu(app, row, offering: item)
        XCTAssertTrue(button.exists, "the menu offers \(item)")
        button.tap()
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
