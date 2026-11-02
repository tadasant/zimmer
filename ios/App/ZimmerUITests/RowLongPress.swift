import XCTest

extension XCTestCase {
    /// A board row's long press, until its menu offers `item`, which it returns. Every test
    /// that opens a row's menu goes through here rather than pressing once.
    ///
    /// Under load a 1.2-second press can land as a tap, which opens the session instead, or
    /// while the last menu is still closing, which opens nothing. CI recordings show the first,
    /// once with a press that took 11 seconds to deliver and a session page that took longer
    /// still to offer its back button. So a press that brings no menu comes back to the board
    /// if it left it, and presses again; a menu that turns up before the next press is taken,
    /// and the last press waits the whole `timeout` for a menu that is merely slow. `prepare`
    /// runs before each press: a scroll that keeps the row clear of the navigation bar, say.
    ///
    /// A press whose accessibility query timed out (see `absorbingAXIPCTimeout`) never reached
    /// the row, so it does not count as one of the presses: it is made again, once.
    ///
    /// Returns the menu item, which does not exist when every press missed: assert on it.
    @MainActor
    func pressForMenu(_ app: XCUIApplication, _ row: XCUIElement, offering item: String,
                      timeout: TimeInterval = 20, prepare: @MainActor () -> Void = {}) -> XCUIElement {
        let button = app.buttons[item].firstMatch
        let attempts = 3
        var presses = 0
        var timedOut = false
        while presses < attempts {
            // Only a session page has a back button called Sessions: the board's own title is not a button.
            let back = app.navigationBars.buttons["Sessions"]
            if presses > 0 || timedOut {
                // A menu that came after the last wait gave up is the menu asked for.
                if button.exists { return button }
            }
            // A press that landed as a tap takes the row off the board before the session page it
            // opens has a back button: the page shows "Loading session…" without one until its
            // read returns. So a missing row means the page is still coming, and its back button
            // is waited for rather than looked for once.
            if presses > 0 || timedOut, back.exists || (!row.exists && back.waitForExistence(timeout: timeout)) {
                back.tap()
                // The page has gone, not merely started to: a press during the pop lands on nothing.
                let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: back)
                XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "back on the board after a press that opened the session")
                XCTAssertTrue(row.waitForExistence(timeout: timeout))
            }
            prepare()
            if timedOut {
                row.press(forDuration: 1.2)
            } else if !absorbingAXIPCTimeout({ row.press(forDuration: 1.2) }) {
                timedOut = true
                if button.exists { return button }
                continue
            }
            presses += 1
            if button.waitForExistence(timeout: presses == attempts ? timeout : 5) { return button }
        }
        return button
    }

    /// Runs `action`, an XCUIElement action, and returns false when XCUITest's own
    /// accessibility IPC timed out under it, recording that as an expected failure rather than
    /// failing the test. Every other issue the action records fails the test as it would have.
    ///
    /// Before it synthesises a press, XCUITest checks for interrupting elements, a system alert
    /// say, by asking SpringBoard which applications are focused. On a loaded CI simulator that
    /// one call has hung for its whole 60-second IPC timeout and come back
    /// `kAXErrorIPCTimeout` ("Failed to get list of active applications"), with the app idle
    /// and the row on screen. The same call returned in 20 ms for the rest of the run
    /// (actions/runs/41371175993, session-page shard). Nothing was pressed. The app did nothing
    /// wrong, and pressing again is the honest answer.
    ///
    /// `continueAfterFailure` is held true for the action, so the test goes on past the absorbed
    /// timeout whatever XCTest does with an expected failure in a test that stops on failures.
    /// An unmatched issue under it still fails the test, and the test then stops at its next
    /// assertion rather than at the action. The waits and taps around the press run the same
    /// check unguarded: this covers the press, where the hang was seen.
    @MainActor
    func absorbingAXIPCTimeout(_ action: @MainActor () -> Void) -> Bool {
        let timedOut = Flag()
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            let text = [issue.compactDescription, issue.detailedDescription ?? "",
                        issue.associatedError.map { String(describing: $0) } ?? ""].joined(separator: " ")
            let matches = text.contains("kAXErrorIPCTimeout")
            if matches { timedOut.raised = true }
            return matches
        }
        let stopsOnFailure = !continueAfterFailure
        continueAfterFailure = true
        defer { continueAfterFailure = !stopsOnFailure }
        XCTExpectFailure("XCUITest's accessibility IPC to the simulator timed out; the action is retried", options: options) {
            action()
        }
        return !timedOut.raised
    }
}

/// Set from the issue matcher, which XCTest calls on the thread that records the issue: the
/// test's own, inside `XCTExpectFailure`'s block, so nothing reads it concurrently.
private final class Flag: @unchecked Sendable {
    var raised = false
}

/// `absorbingAXIPCTimeout`, against issues recorded by hand: nothing here launches the app, so
/// it costs the shard a second. It proves what the press retry relies on and cannot be made to
/// happen on demand: the timeout is absorbed and the test goes on, and nothing else is.
@MainActor
final class RowLongPressUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func test_an_ax_ipc_timeout_is_absorbed_and_reported() {
        var ran = false
        let clean = absorbingAXIPCTimeout {
            XCTFail("Failed to get list of active applications: Accessibility error kAXErrorIPCTimeout from AXUIElementCopyMultipleAttributeValues for 1102")
            ran = true
        }
        XCTAssertTrue(ran, "the test goes on past an absorbed timeout")
        XCTAssertFalse(clean, "a timed-out action reports itself, so the press is made again")
    }

    func test_an_action_that_records_nothing_is_clean() {
        XCTAssertTrue(absorbingAXIPCTimeout {}, "nothing recorded, nothing absorbed")
    }

    func test_any_other_failure_still_fails() {
        // The outer, strict expectation is what catches the inner failure, which it can only
        // do if absorbingAXIPCTimeout let it through. Strict: had nothing reached it, the
        // test would fail.
        XCTExpectFailure("an ordinary failure inside the action is not absorbed") {
            _ = absorbingAXIPCTimeout { XCTFail("the menu offers Promote to Priority") }
        }
    }
}
