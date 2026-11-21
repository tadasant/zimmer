import XCTest

extension XCTestCase {
    /// Taps `title` in the confirmation dialog on screen until the dialog takes it. Every test
    /// that signs off on a write in a `confirmationDialog` goes through here rather than tapping
    /// once. A dialog's button carries no identifier, so it is found by its title.
    ///
    /// Under load the tap can be lost. On main's run 44930302886 (photos shard) XCUITest found
    /// the dialog's Merge #1261, synthesised the tap on it, and the dialog was still up 20 seconds
    /// later, "Authorize the merge?" and all, with nothing in the toast log: the button's action,
    /// which also dismisses the dialog, never ran. A person taps again; so does this, but only
    /// while the button is still there and hittable, so a dialog that took the tap and is gone,
    /// or going, is not tapped again and the write is made once. The last try waits the full
    /// `timeout`, so the worst case is 30 seconds.
    @MainActor
    func confirmInDialog(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        let button = app.sheets.buttons[title].firstMatch
        guard button.waitForExistence(timeout: timeout) else {
            XCTFail("no confirmation offering \(title)", file: file, line: line)
            return
        }
        let gone = NSPredicate(format: "exists == false")
        let attempts = 3
        for attempt in 1...attempts {
            if attempt > 1 {
                guard button.exists, button.isHittable else { return }
                add(XCTAttachment(string: "the dialog was still up after tap \(attempt - 1) on \(title):\n\(app.debugDescription)"))
            }
            button.tap()
            let left = XCTNSPredicateExpectation(predicate: gone, object: button)
            if XCTWaiter().wait(for: [left], timeout: attempt == attempts ? timeout : 5) == .completed { return }
        }
        XCTFail("the dialog took none of \(attempts) taps on \(title)", file: file, line: line)
    }
}
