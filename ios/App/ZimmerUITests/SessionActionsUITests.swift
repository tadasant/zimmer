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

    func test_open_a_session_answer_it_and_trash_it() throws {
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

        // It is running now, and the web UI trashes a running session outright: no question
        // first, the page closes, and the board offers Undo for as long as the server would.
        app.buttons["detail.archive"].tap()
        let undo = app.buttons["toast.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["session.row.1038"]), "the trashed session left the board")
        attachScreenshot(app, named: "trash-undo")
        undo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].waitForExistence(timeout: timeout), "Undo brought it back")

        // 1042 has messages queued for it: trashing asks first, naming the discard — the web
        // UI's *Archive anyway*. It is running, so it is under Active.
        XCTAssertTrue(app.buttons["filter.active"].waitForExistence(timeout: timeout))
        app.buttons["filter.active"].tap()
        let queued = app.descendants(matching: .any)["session.row.1042"]
        XCTAssertTrue(queued.waitForExistence(timeout: timeout))
        queued.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.summary"].waitForExistence(timeout: timeout))
        app.buttons["detail.archive"].tap()
        let anyway = app.buttons["Trash anyway"].firstMatch
        XCTAssertTrue(anyway.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "trash-queued")
        anyway.tap()
        XCTAssertTrue(app.buttons["toast.undo"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["session.row.1042"]), "trashed anyway, it left the board")
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
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

    /// The bar's sparkles open the sheet with the words so far, and a start from the sheet
    /// leaves the bar empty as well as the sheet: the words typed before the sheet opened do
    /// not outlive the session they started. Closing the sheet without starting gives the bar
    /// the sheet's words, edits included.
    func test_a_start_from_the_sheet_the_bar_opened_leaves_the_bar_empty() throws {
        let app = launch()

        let bar = app.descendants(matching: .any)["quickrouter.bar.field"]
        XCTAssertTrue(bar.waitForExistence(timeout: timeout))
        bar.tap()
        bar.typeText("Rotate the staging")
        app.buttons["quickrouter.bar.more"].tap()

        // The sheet starts with the bar's words; more are typed there before Start.
        let sheet = app.descendants(matching: .any)["quickrouter.field"]
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForValue(sheet, "Rotate the staging"))
        XCTAssertTrue(waitForKeyboardFocus(sheet))
        sheet.typeText(" deploy key")
        app.buttons["quickrouter.start"].tap()

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        XCTAssertEqual(title.label, "Rotate the staging deploy key")
        attachScreenshot(app, named: "quick-router-sheet-started")

        app.navigationBars.buttons["Sessions"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForEmpty(bar), "the bar is empty after a start, not \(String(describing: bar.value))")
        attachScreenshot(app, named: "quick-router-bar-empty-after-start")

        // Reopened, the sheet is empty too.
        app.buttons["quickrouter.bar.more"].tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForEmpty(sheet), "the reopened sheet is empty, not \(String(describing: sheet.value))")
        attachScreenshot(app, named: "quick-router-sheet-empty-after-start")

        // Closed without starting, the sheet gives the bar its words.
        XCTAssertTrue(waitForKeyboardFocus(sheet))
        sheet.typeText("Draft the release notes")
        app.navigationBars["Quick Router"].buttons["Cancel"].tap()
        XCTAssertTrue(waitForDisappearance(sheet))
        XCTAssertTrue(waitForValue(bar, "Draft the release notes"), "a Cancel gives the bar the sheet's words")
    }

    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [match], timeout: timeout) == .completed
    }

    /// An empty text field reads back as nothing or as its placeholder, by iOS version.
    private func waitForEmpty(_ field: XCUIElement) -> Bool {
        let empty = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == nil OR value == '' OR value == %@", "What do you want to do?"),
            object: field
        )
        return XCTWaiter().wait(for: [empty], timeout: timeout) == .completed
    }

    /// The sheet focuses its field as it appears; typing waits for that rather than tapping,
    /// which would put the cursor wherever the tap landed.
    private func waitForKeyboardFocus(_ element: XCUIElement) -> Bool {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }

    /// The button in the corner of every other screen: the web UI's bubble. From the Inbox
    /// it opens the sheet, and the session it starts opens on the Sessions tab.
    func test_the_quick_router_button_is_in_the_corner_of_the_inbox_and_opens_the_sheet() throws {
        // The sheet opens with Advanced already unfolded, as the screenshot run opens it.
        let app = launch(arguments: ["-ZimmerFixtureTab", "inbox", "-ZimmerFixtureQuickRouterAdvanced"])

        let button = app.buttons["quickrouter.fab"]
        XCTAssertTrue(button.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "inbox-quick-router-button")
        button.tap()
        let field = app.descendants(matching: .any)["quickrouter.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Draft the release notes")
        attachScreenshot(app, named: "quick-router")

        // The web bubble's Advanced accordion: harness, model, spot. Spot is chosen here, and
        // the session it starts is read back as spot.
        let spot = app.switches["quickrouter.spot"]
        XCTAssertTrue(spot.waitForExistence(timeout: timeout))
        spot.tap()
        attachScreenshot(app, named: "quick-router-advanced")
        app.buttons["quickrouter.start"].tap()

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        XCTAssertEqual(title.label, "Draft the release notes")
        XCTAssertFalse(app.staticTexts["Priority"].exists, "a spot start is not a priority session")
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
