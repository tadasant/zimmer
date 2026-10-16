import XCTest

/// The keyboard goes when the Quick Router sends, from the board's bar and from the sheet the
/// bar opened, and stays gone on the session that opens and back on the board. A scroll of the
/// board puts it away by hand.
@MainActor
final class QuickRouterKeyboardUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_sending_from_the_bar_puts_the_keyboard_away() throws {
        let app = launch()

        let field = app.descendants(matching: .any)["quickrouter.bar.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Rotate the staging deploy key")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: timeout))
        app.buttons["quickrouter.bar.start"].tap()

        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForNoKeyboard(app), "the keyboard is gone on the session that opened")
        attachScreenshot(app, named: "quick-router-bar-sent-no-keyboard")

        app.navigationBars.buttons["Sessions"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForNoKeyboard(app), "the keyboard does not come back on the board")
        XCTAssertFalse(field.hasKeyboardFocus, "the bar is not focused again")
    }

    func test_starting_from_the_sheet_the_bar_opened_leaves_no_keyboard_on_the_board() throws {
        let app = launch()

        let bar = app.descendants(matching: .any)["quickrouter.bar.field"]
        XCTAssertTrue(bar.waitForExistence(timeout: timeout))
        bar.tap()
        bar.typeText("Draft the release notes")
        app.buttons["quickrouter.bar.more"].tap()
        let sheet = app.descendants(matching: .any)["quickrouter.field"]
        XCTAssertTrue(sheet.waitForExistence(timeout: timeout))
        // Off, the board stays under the sheet, so it is the board's keyboard being checked.
        let open = app.switches["quickrouter.open"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        app.buttons["quickrouter.start"].tap()

        XCTAssertTrue(waitForDisappearance(sheet))
        XCTAssertTrue(bar.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForNoKeyboard(app), "the bar did not take the keyboard back as the sheet closed")
        XCTAssertFalse(bar.hasKeyboardFocus, "the bar is not focused again")
        attachScreenshot(app, named: "quick-router-sheet-sent-no-keyboard")
    }

    func test_a_scroll_of_the_board_puts_the_keyboard_away() throws {
        let app = launch()

        let field = app.descendants(matching: .any)["quickrouter.bar.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: timeout))
        let row = app.descendants(matching: .any)["session.row.1038"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        row.swipeDown()
        XCTAssertTrue(waitForNoKeyboard(app), "a scroll of the board dismisses the keyboard")
    }

    private func waitForNoKeyboard(_ app: XCUIApplication) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.keyboards)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"]
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
