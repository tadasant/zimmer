import XCTest

/// Merge and Reprioritize against the `-ZimmerFixture` in-memory Zimmer, where session 1038
/// holds PR #1261, open with CI green.
@MainActor
final class DecisionsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_merge_from_a_rows_long_press_asks_first_then_says_it_went() throws {
        let app = launch()
        let row = app.descendants(matching: .any)["session.row.1038"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        row.press(forDuration: 1.0)
        let merge = app.buttons["Merge #1261"].firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: timeout))
        merge.tap()

        // The confirmation names the PR; the tap is the sign-off.
        let confirm = app.sheets.buttons["Merge #1261"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["toast"], "Merge authorized"))
    }

    func test_merge_from_the_session_menu() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        let actions = app.buttons["detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: timeout))
        actions.tap()
        let item = app.buttons["Merge #1261"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: timeout))
        item.tap()
        let confirm = app.sheets.buttons["Merge #1261"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["followup.notice"], "Merge authorized"))
    }

    func test_reprioritize_from_the_view_menu_names_the_session_that_took_it() throws {
        let app = launch(["-ZimmerFixtureView", "user"])
        let menu = app.buttons["board.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()
        let item = app.buttons["Reprioritize"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: timeout))
        item.tap()
        let confirm = app.sheets.buttons["Reprioritize"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["toast"], "is re-ranking the board"))
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter().wait(for: [match], timeout: timeout) == .completed
    }
}
