import XCTest

/// The keyboard goes when the Quick Router sends, from the board's bar and from the sheet the
/// bar opened, and stays gone on the session that opens and back on the board. A scroll of the
/// board puts it away by hand, and so does the bar's Cancel, which empties it as the search
/// box's Cancel empties the search.
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
        XCTAssertTrue(staysWithoutKeyboard(app), "the keyboard does not come back on the board")
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
        XCTAssertTrue(waitForKeyboardFocus(sheet))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: timeout))
        // Off, the board stays under the sheet, so it is the board's keyboard being checked.
        let open = app.switches["quickrouter.open"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout))
        open.tap()
        XCTAssertEqual(open.value as? String, "0")
        app.buttons["quickrouter.start"].tap()

        XCTAssertTrue(waitForDisappearance(sheet))
        XCTAssertTrue(bar.waitForExistence(timeout: timeout))
        XCTAssertTrue(staysWithoutKeyboard(app), "the bar did not take the keyboard back as the sheet closed")
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
        row.swipeUp()
        XCTAssertTrue(waitForNoKeyboard(app), "a scroll of the board dismisses the keyboard")
    }

    func test_cancel_puts_the_bar_back_at_rest() throws {
        let app = launch()

        let field = app.descendants(matching: .any)["quickrouter.bar.field"]
        let cancel = app.buttons["quickrouter.bar.cancel"]
        let start = app.buttons["quickrouter.bar.start"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        XCTAssertFalse(cancel.exists, "no Cancel while the bar is at rest")
        field.tap()
        field.typeText("Rotate the staging deploy key")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: timeout))
        XCTAssertTrue(cancel.waitForExistence(timeout: timeout), "Cancel stands beside the bar while it has the keyboard")
        XCTAssertEqual(cancel.label, "Cancel", "the X still reads as Cancel")
        // Across the field from send, so a thumb reaching for one does not land on the other.
        XCTAssertLessThan(cancel.frame.maxX, field.frame.minX, "Cancel is on the field's leading side")
        XCTAssertLessThan(field.frame.maxX, start.frame.minX, "send is alone on the trailing side")
        XCTAssertTrue(start.isEnabled)
        attachScreenshot(app, named: "quick-router-bar-focused-cancel")

        cancel.tap()

        XCTAssertTrue(staysWithoutKeyboard(app), "Cancel puts the keyboard away")
        XCTAssertTrue(waitForDisappearance(cancel), "Cancel goes with the keyboard")
        XCTAssertFalse(start.isEnabled, "the words went with Cancel, so there is nothing to send")
        // An empty field reports its placeholder or nothing, depending on the text view behind it.
        let value = try XCTUnwrap(field.value as? String, "the field reports a value")
        XCTAssertTrue(["", "What do you want to do?"].contains(value), "the bar is empty, not \(value)")
        attachScreenshot(app, named: "quick-router-bar-cancelled")
    }

    private func waitForNoKeyboard(_ app: XCUIApplication) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.keyboards)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Gone, and still gone a moment later: a keyboard UIKit hands back to the bar arrives
    /// after the one the send put away has left, so a single look could pass between the two.
    private func staysWithoutKeyboard(_ app: XCUIApplication) -> Bool {
        waitForNoKeyboard(app) && !app.keyboards.firstMatch.waitForExistence(timeout: 3)
    }

    private func waitForKeyboardFocus(_ element: XCUIElement) -> Bool {
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
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
