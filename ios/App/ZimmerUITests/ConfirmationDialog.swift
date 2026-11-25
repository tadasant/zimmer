import XCTest

extension XCTestCase {
    /// Taps `title` in the confirmation dialog on screen until the dialog takes it. The tests in
    /// `DecisionsUITests` sign off through here rather than tapping once; other confirmations in
    /// the suite still tap once (see limitations.md). A dialog's button carries no identifier, so
    /// it is found by its title.
    ///
    /// Under load the tap can be lost. On main's run 44930302886 (photos shard) XCUITest found
    /// the dialog's Merge #1261, synthesised the tap on it, and the dialog was still up 20 seconds
    /// later, "Authorize the merge?" and all, with nothing in the toast log: the button's action,
    /// which also dismisses the dialog, never ran. A person taps again; so does this, but only
    /// while the button is still there, 5 seconds after the last tap, so a dialog that took the
    /// tap is gone and the write is made once. Each retry keeps the app's hierarchy as an
    /// attachment, on green runs too, so how often a tap is lost stays visible. The taps wait at
    /// most 30 seconds, after up to `timeout` for the dialog to appear.
    @MainActor
    func confirmInDialog(_ app: XCUIApplication, _ title: String, timeout: TimeInterval = 20,
                         file: StaticString = #filePath, line: UInt = #line) {
        let button = app.sheets.buttons[title].firstMatch
        guard button.waitForExistence(timeout: timeout) else {
            XCTFail("no confirmation offering \(title)", file: file, line: line)
            return
        }
        let attempts = 3
        for attempt in 1...attempts {
            if attempt > 1 {
                guard button.exists else { return }
                let still = XCTAttachment(string: app.debugDescription)
                still.name = "the dialog was still up after tap \(attempt - 1) on \(title)"
                still.lifetime = .keepAlways
                add(still)
            }
            button.tap()
            if waitForDisappearance(button, timeout: attempt == attempts ? timeout : 5) { return }
        }
        XCTFail("the dialog took none of \(attempts) taps on \(title)", file: file, line: line)
    }
}
