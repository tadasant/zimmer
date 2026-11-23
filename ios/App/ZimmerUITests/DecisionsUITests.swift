import XCTest

/// Merge against the `-ZimmerFixture` in-memory Zimmer, where session 1038
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
        let merge = pressForMenu(app, row, offering: "Merge #1261")
        XCTAssertTrue(merge.exists, "the menu offers Merge #1261")
        merge.tap()

        // The confirmation names the PR; the tap is the sign-off.
        confirmInDialog(app, "Merge #1261")
        XCTAssertTrue(waitForToast(app, saying: "Merge authorized", on: "toast"))
    }

    func test_merge_from_the_session_menu() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        let actions = app.buttons["detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: timeout))
        actions.tap()
        let item = app.buttons["Merge #1261"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: timeout))
        item.tap()
        confirmInDialog(app, "Merge #1261")
        XCTAssertTrue(waitForToast(app, saying: "Merge authorized", on: "followup.notice"))
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }
}
