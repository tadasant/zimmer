import XCTest

/// An action shows at the tap, before the server has answered, and is put back when the server
/// refuses it — against the `-ZimmerFixture` in-memory Zimmer, whose answers can be held back
/// (`FixtureHold`) and refused (`-ZimmerFixtureRefuse <names>`).
@MainActor
final class OptimisticActionsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_trash_leaves_the_board_at_the_tap_and_comes_back_when_the_server_refuses() throws {
        let hold = FixtureHold("trash")
        let app = launch(["-ZimmerFixtureRefuse", "trash"] + hold.arguments)
        let row = app.descendants(matching: .any)["session.row.1038"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))

        let trash = pressForMenu(app, row, offering: "Trash")
        XCTAssertTrue(trash.exists, "the row's menu offers Trash")
        trash.tap()

        // At the tap: the row is gone and Undo is offered, with the fixture's answer held.
        let undo = app.buttons["toast.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: timeout), "Undo is offered before the server answers")
        XCTAssertTrue(waitForDisappearance(row), "the row left the board before the server answered")
        hold.assertStillHeld()
        attachScreenshot(app, named: "trash-at-the-tap")
        hold.answer()

        // The refusal: a toast says the row was not moved, the row is back, the Undo gone. The
        // refusal's banner is the list's first row too, which a list the press and the menu
        // scrolled may hold off screen; the toast at the foot is what this looks for.
        XCTAssertTrue(waitForToast(app, saying: "Not moved to trash", on: "toast", timeout: timeout), "the refusal shows over the board")
        attachScreenshot(app, named: "trash-put-back")
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "the refused trash put the row back")
        XCTAssertTrue(waitForDisappearance(undo), "nothing to undo")
    }

    func test_a_follow_up_shows_at_the_tap_and_keeps_its_words_when_the_server_refuses() throws {
        let hold = FixtureHold("follow_up")
        let app = launch(["-ZimmerFixtureOpenSession", "1038", "-ZimmerFixtureRefuse", "follow_up"] + hold.arguments)
        let field = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Yes, merge it.")
        app.buttons["followup.send"].tap()

        // At the tap: the composer is empty and the message is under the conversation.
        let sending = app.descendants(matching: .any)["outgoing.sending"]
        XCTAssertTrue(sending.waitForExistence(timeout: timeout), "the message shows before the server answers")
        XCTAssertNotEqual(field.value as? String, "Yes, merge it.", "the composer let the words go")
        hold.assertStillHeld()
        attachScreenshot(app, named: "follow-up-at-the-tap")
        hold.answer()

        // The refusal: the message stays, marked not sent, with its words kept.
        let failed = app.descendants(matching: .any)["outgoing.failed"]
        XCTAssertTrue(failed.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["outgoing.retry"].exists)
        attachScreenshot(app, named: "follow-up-not-sent")
        app.buttons["outgoing.edit"].tap()
        XCTAssertTrue(waitForDisappearance(failed))
        XCTAssertEqual(field.value as? String, "Yes, merge it.", "Edit put the words back in the composer")
    }

    func test_the_quick_router_opens_the_page_at_the_tap() throws {
        let hold = FixtureHold("quick_router")
        let app = launch(hold.arguments)
        let field = app.descendants(matching: .any)["quickrouter.bar.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Rotate the staging deploy key")
        app.buttons["quickrouter.bar.start"].tap()

        // At the tap: the page is open, with the words on their way.
        XCTAssertTrue(app.descendants(matching: .any)["start.pending"].waitForExistence(timeout: timeout), "the page opened before the server answered")
        XCTAssertTrue(app.descendants(matching: .any)["outgoing.sending"].waitForExistence(timeout: timeout), "with the words on it")
        hold.assertStillHeld()
        attachScreenshot(app, named: "quick-router-at-the-tap")
        hold.answer()

        // The answer: the session fills the page in.
        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout), "the session filled the page in once it existed")
        XCTAssertEqual(title.label, "Rotate the staging deploy key")
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["start.pending"]))
        attachScreenshot(app, named: "quick-router-started")
    }

    func test_a_quick_router_start_the_server_refuses_keeps_the_words() throws {
        let app = launch(["-ZimmerFixtureRefuse", "quick_router"])
        let field = app.descendants(matching: .any)["quickrouter.bar.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Rotate the staging deploy key")
        app.buttons["quickrouter.bar.start"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["start.failed"].waitForExistence(timeout: timeout), "the page says the start failed")
        // The header's buttons are styled; found by identifier whatever element type they read as.
        XCTAssertTrue(app.descendants(matching: .any)["start.retry"].waitForExistence(timeout: timeout), "Try again is offered")
        let edit = app.descendants(matching: .any)["start.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: timeout), "Edit is offered")
        attachScreenshot(app, named: "quick-router-refused")

        // Edit: the words back in the Quick Router, for another go.
        edit.tap()
        let sheet = app.descendants(matching: .any)["quickrouter.field"]
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout))
        XCTAssertEqual(sheet.value as? String, "Rotate the staging deploy key")
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Beside the result bundle too, where a pull request can take it from the artifact.
        if let directory = ProcessInfo.processInfo.environment["ZIMMER_UI_TEST_ARTIFACTS"], !directory.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("test-\(name).png"))
        }
    }
}
