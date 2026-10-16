import XCTest

extension XCTestCase {
    /// A board row's long press, until its menu offers `item`, which it returns. Every test
    /// that opens a row's menu goes through here rather than pressing once.
    ///
    /// Under load a 1.2-second press can land as a tap, which opens the session instead, or
    /// while the last menu is still closing, which opens nothing. CI recordings show both
    /// (`BoardReadParityUITests`, then `SessionControlsUITests` on run 38939005183, where the
    /// press opened #1038's page). So a press that brings no menu comes back to the board if
    /// it left it, and presses again. `prepare` runs before each press: a scroll that keeps
    /// the row clear of the navigation bar, say.
    ///
    /// Returns the menu item, which does not exist when every press missed: assert on it.
    @MainActor
    func pressForMenu(_ app: XCUIApplication, _ row: XCUIElement, offering item: String,
                      timeout: TimeInterval = 20, prepare: @MainActor () -> Void = {}) -> XCUIElement {
        let button = app.buttons[item].firstMatch
        for attempt in 0..<3 {
            // Only a session page has a back button called Sessions: the board's own title is not a button.
            if attempt > 0, app.navigationBars.buttons["Sessions"].exists {
                app.navigationBars.buttons["Sessions"].tap()
                XCTAssertTrue(row.waitForExistence(timeout: timeout), "back on the board after a press that opened the session")
            }
            prepare()
            row.press(forDuration: 1.2)
            if button.waitForExistence(timeout: 5) { return button }
        }
        return button
    }
}
