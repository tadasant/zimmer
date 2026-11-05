import XCTest

extension XCTestCase {
    /// Whether a toast has said `words`, or anything at all without them, since the app launched.
    /// `identifier` names the toast, for words that an earlier toast elsewhere also said; the
    /// words must then begin what it said.
    ///
    /// Read from the fixture's `ToastLog`, never from the toast. It is on screen for 2.5 seconds,
    /// and an action's `tap()` returns only when the app's animations settle: on a loaded
    /// simulator that was 3.2 seconds, after the toast had gone, and a predicate is first read a
    /// second later still (actions/runs/41988218184). The log keeps every toast, so this needs
    /// only the words the action should have produced, not a moment to catch them in.
    @MainActor
    func waitForToast(_ app: XCUIApplication, saying words: String = "", on identifier: String = "",
                      timeout: TimeInterval = 20) -> Bool {
        let wanted = identifier.isEmpty && !words.isEmpty ? words : "\(identifier): \(words)"
        let said = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", wanted),
                                             object: app.staticTexts["toast.log"])
        return XCTWaiter().wait(for: [said], timeout: timeout) == .completed
    }
}
