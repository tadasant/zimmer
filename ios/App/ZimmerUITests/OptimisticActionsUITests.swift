import XCTest

/// An action shows at the tap, before the server has answered, and is put back when the server
/// refuses it — against the `-ZimmerFixture` in-memory Zimmer, whose writes can be made slow
/// (`-ZimmerFixtureSlowWrites`, six seconds) and refused (`-ZimmerFixtureRefuse <names>`).
@MainActor
final class OptimisticActionsUITests: XCTestCase {
    private let timeout: TimeInterval = 20
    /// Each wait for something that should show at the tap. Two in a row stay well inside the
    /// fixture's six-second write delay, and `assertBeforeTheAnswer` checks that they did.
    private let atTheTap: TimeInterval = 2
    private let writeDelay: TimeInterval = 6

    override func setUp() {
        continueAfterFailure = false
    }

    func test_trash_leaves_the_board_at_the_tap_and_comes_back_when_the_server_refuses() throws {
        let app = launch(["-ZimmerFixtureRefuse", "trash", "-ZimmerFixtureSlowWrites"])
        let row = app.descendants(matching: .any)["session.row.1038"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))

        let trash = pressForMenu(app, row, offering: "Trash")
        XCTAssertTrue(trash.exists, "the row's menu offers Trash")
        trash.tap()
        let tapped = Date()

        // At the tap: the row is gone and Undo is offered, before the fixture has answered.
        let undo = app.buttons["toast.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: atTheTap), "Undo is offered before the server answers")
        XCTAssertTrue(waitForDisappearance(row, within: atTheTap), "the row left the board before the server answered")
        assertBeforeTheAnswer(tapped)
        attachScreenshot(app, named: "trash-at-the-tap")

        // The refusal: a toast says the row was not moved, the row is back, the Undo gone. The
        // refusal's banner is the list's first row too, which a list the press and the menu
        // scrolled may hold off screen; the toast at the foot is what this looks for.
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'toast' AND label CONTAINS 'Not moved to trash'")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: timeout), "the refusal shows over the board")
        attachScreenshot(app, named: "trash-put-back")
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "the refused trash put the row back")
        XCTAssertTrue(waitForDisappearance(undo, within: timeout), "nothing to undo")
    }

    func test_a_follow_up_shows_at_the_tap_and_keeps_its_words_when_the_server_refuses() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038", "-ZimmerFixtureRefuse", "follow_up", "-ZimmerFixtureSlowWrites"])
        let field = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Yes, merge it.")
        app.buttons["followup.send"].tap()
        let tapped = Date()

        // At the tap: the composer is empty and the message is under the conversation.
        let sending = app.descendants(matching: .any)["outgoing.sending"]
        XCTAssertTrue(sending.waitForExistence(timeout: atTheTap), "the message shows before the server answers")
        XCTAssertNotEqual(field.value as? String, "Yes, merge it.", "the composer let the words go")
        assertBeforeTheAnswer(tapped)
        attachScreenshot(app, named: "follow-up-at-the-tap")

        // The refusal: the message stays, marked not sent, with its words kept.
        let failed = app.descendants(matching: .any)["outgoing.failed"]
        XCTAssertTrue(failed.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["outgoing.retry"].exists)
        attachScreenshot(app, named: "follow-up-not-sent")
        app.buttons["outgoing.edit"].tap()
        XCTAssertTrue(waitForDisappearance(failed, within: timeout))
        XCTAssertEqual(field.value as? String, "Yes, merge it.", "Edit put the words back in the composer")
    }

    func test_the_quick_router_opens_the_page_at_the_tap() throws {
        let app = launch(["-ZimmerFixtureSlowWrites"])
        let field = app.descendants(matching: .any)["quickrouter.bar.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Rotate the staging deploy key")
        app.buttons["quickrouter.bar.start"].tap()
        let tapped = Date()

        // At the tap: the page is open, with the words on their way.
        XCTAssertTrue(app.descendants(matching: .any)["start.pending"].waitForExistence(timeout: atTheTap), "the page opened before the server answered")
        XCTAssertTrue(app.descendants(matching: .any)["outgoing.sending"].exists, "with the words on it")
        assertBeforeTheAnswer(tapped)
        attachScreenshot(app, named: "quick-router-at-the-tap")

        // The answer: the session fills the page in.
        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout), "the session filled the page in once it existed")
        XCTAssertEqual(title.label, "Rotate the staging deploy key")
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["start.pending"], within: timeout))
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

    /// What was just asserted showed before the fixture could have answered: otherwise the
    /// test proved nothing about the tap, only about the answer.
    private func assertBeforeTheAnswer(_ tapped: Date) {
        XCTAssertLessThan(Date().timeIntervalSince(tapped), writeDelay, "asserted before the fixture's write delay had passed")
    }

    private func waitForDisappearance(_ element: XCUIElement, within limit: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: limit) == .completed
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
