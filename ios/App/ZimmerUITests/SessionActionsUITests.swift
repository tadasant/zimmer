import XCTest

/// A session from the list to done, against the `-ZimmerFixture` in-memory Zimmer:
/// open it, read where it stands, answer it, archive it. And the Quick Router, which
/// starts one from a sentence.
@MainActor
final class SessionActionsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_open_a_session_answer_it_and_archive_it() throws {
        let app = launch()

        let row = app.descendants(matching: .any)["session.row.1038"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        row.tap()

        // Where it stands, and what the agent last said. The conversation loads after the
        // summary, so it is waited for rather than checked at once.
        XCTAssertTrue(app.descendants(matching: .any)["detail.summary"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["detail.title"].label.contains("PR #1261"))
        XCTAssertTrue(app.descendants(matching: .any)["detail.message.2"].waitForExistence(timeout: timeout), "the agent's question is shown")
        XCTAssertFalse(app.descendants(matching: .any)["detail.message.1"].exists, "tool calls are folded away by default")
        attachScreenshot(app, named: "detail")

        // Answer it: the follow-up lands in the conversation and the session runs again.
        // A multi-line TextField is a text view to XCUITest, so it is found by identifier.
        let field = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Yes, merge it.")
        app.buttons["followup.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["followup.notice"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["detail.message.3"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["detail.status"].label, "Running")
        attachScreenshot(app, named: "detail-after-follow-up")

        // It is running now, so trashing it is refused — as the server refuses a session
        // mid-turn — and the refusal is shown rather than swallowed. The dialog's button
        // is "Trash", the web UI's word; the toolbar's is labelled "Move to trash".
        app.buttons["detail.archive"].tap()
        let refusedConfirm = app.buttons["Trash"].firstMatch
        XCTAssertTrue(refusedConfirm.waitForExistence(timeout: timeout))
        refusedConfirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["error.banner"].waitForExistence(timeout: timeout))

        // Archive one that is waiting on a person: back on the list, and it is gone.
        app.navigationBars.buttons["Sessions"].tap()
        let other = app.descendants(matching: .any)["session.row.1035"]
        XCTAssertTrue(other.waitForExistence(timeout: timeout))
        other.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.summary"].waitForExistence(timeout: timeout))
        app.buttons["detail.archive"].tap()
        let confirm = app.buttons["Trash"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(app.buttons["filter.active"].waitForExistence(timeout: timeout))
        app.buttons["filter.active"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1042"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.descendants(matching: .any)["session.row.1035"].exists, "the archived session left Active")
    }

    /// The bar at the foot of the board: the web UI's "What do you want to do?" box.
    func test_the_quick_router_bar_starts_a_session_from_a_sentence_and_opens_it() throws {
        let app = launch()

        let field = app.descendants(matching: .any)["quickrouter.bar.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Rotate the staging deploy key")
        attachScreenshot(app, named: "quick-router-bar")
        app.buttons["quickrouter.bar.start"].tap()

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        XCTAssertEqual(title.label, "Rotate the staging deploy key")
        XCTAssertEqual(app.staticTexts["detail.status"].label, "Waiting")
    }

    /// The button in the corner of every other screen: the web UI's bubble. From the Inbox
    /// it opens the sheet, and the session it starts opens on the Sessions tab.
    func test_the_quick_router_button_is_in_the_corner_of_the_inbox_and_opens_the_sheet() throws {
        let app = launch(arguments: ["-ZimmerFixtureTab", "inbox"])

        let button = app.buttons["quickrouter.fab"]
        XCTAssertTrue(button.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "inbox-quick-router-button")
        button.tap()
        let field = app.descendants(matching: .any)["quickrouter.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Draft the release notes")
        attachScreenshot(app, named: "quick-router")
        app.buttons["quickrouter.start"].tap()

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        XCTAssertEqual(title.label, "Draft the release notes")
    }

    private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
