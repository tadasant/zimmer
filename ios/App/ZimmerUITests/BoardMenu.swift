import XCTest

extension XCTestCase {
    /// Chooses `item`, a view or a board visibility, from the board's view options menu, and
    /// returns once the menu has closed on it. Every test that picks from that menu goes through
    /// here rather than tapping once.
    ///
    /// Under load the tap on an item can be lost with the menu open and drawn. On main's run
    /// 44118288577 (board shard, attempt 2) XCUITest found "Snoozed & hidden", synthesised the
    /// tap, and the recording shows the menu still open with "On board" ticked for the whole
    /// 20-second wait that followed: nothing chosen, and the test failed on a row the choice
    /// would have shown. The menu closes on a choice that lands, so a menu still open a few
    /// seconds after the tap is a tap that missed, and the item is tapped again. Choosing the
    /// item already ticked changes nothing, so a tap that landed slowly costs no more than a
    /// second look.
    ///
    /// Whether the menu is open is read from Select Sessions, an item the menu always offers
    /// and nothing on the board itself carries.
    @MainActor
    func chooseFromBoardMenu(_ app: XCUIApplication, _ item: String, timeout: TimeInterval = 20) {
        let open = app.buttons["Select Sessions"].firstMatch
        let choice = app.buttons[item].firstMatch
        let attempts = 3
        for attempt in 1...attempts {
            if !open.exists {
                let menu = app.buttons["board.menu"]
                XCTAssertTrue(menu.waitForExistence(timeout: timeout), "the board's view options")
                menu.tap()
                guard open.waitForExistence(timeout: timeout) else { continue }
            }
            XCTAssertTrue(choice.waitForExistence(timeout: timeout), "the board menu offers \(item)")
            choice.tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: open)
            if XCTWaiter().wait(for: [closed], timeout: attempt == attempts ? timeout : 5) == .completed { return }
        }
        XCTFail("the board menu was still open after \(attempts) taps on \(item)")
    }
}
