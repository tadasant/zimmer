import XCTest

extension XCTestCase {
    /// A board row's long press, until its menu offers `item`, which it returns. Every test
    /// that opens a row's menu goes through here rather than pressing once.
    ///
    /// Under load a 1.2-second press can land as a tap, which opens the session instead, or
    /// while the last menu is still closing, which opens nothing. CI recordings show the first.
    /// So a press that brings no menu comes back to the board if it left it, and presses again;
    /// the last press waits the whole `timeout` for a menu that is merely slow. `prepare` runs
    /// before each press: a scroll that keeps the row clear of the navigation bar, say.
    ///
    /// Returns the menu item, which does not exist when every press missed: assert on it.
    @MainActor
    func pressForMenu(_ app: XCUIApplication, _ row: XCUIElement, offering item: String,
                      timeout: TimeInterval = 20, prepare: @MainActor () -> Void = {}) -> XCUIElement {
        let button = app.buttons[item].firstMatch
        let attempts = 3
        for attempt in 0..<attempts {
            // Only a session page has a back button called Sessions: the board's own title is not a button.
            let back = app.navigationBars.buttons["Sessions"]
            if attempt > 0, back.exists {
                back.tap()
                // The page has gone, not merely started to: a press during the pop lands on nothing.
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: back)
                XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "back on the board after a press that opened the session")
                XCTAssertTrue(row.waitForExistence(timeout: timeout))
            }
            prepare()
            row.press(forDuration: 1.2)
            if button.waitForExistence(timeout: attempt == attempts - 1 ? timeout : 5) { return button }
        }
        return button
    }
}
