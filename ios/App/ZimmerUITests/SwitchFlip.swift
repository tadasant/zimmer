import XCTest

extension XCTestCase {
    /// Flip a switch the way a thumb does, and wait for its value to change. Every switch in the
    /// UI tests goes through here, and `tap()` on one is a bug.
    ///
    /// iOS 26's `UISwitch` flips through a long-press recognizer that begins a beat after the
    /// touch lands. `tap()` holds for 67 ms, and with touch logging on the first touch of a screen
    /// reached the app 50 to 100 ms late, so down and up arrived together and the recognizer never
    /// began. That accounts for most lost taps: a delivered tap, a switch that does not move,
    /// nothing in the log. A plain tap did it 1 time in 53 with nothing logging, with the same
    /// failure as run 41951747877. A press of 200 ms is about a person's tap. On the Quick Router's
    /// visible switch 461 in a row flipped, though 2 in 50 were lost before `QuickRouterSwitch`.
    ///
    /// One press and no retry, on purpose. Why a press this long would be lost is not known, and a
    /// retry would hide it from the suite, so it fails the test to be looked at.
    @MainActor
    func flip(_ toggle: XCUIElement, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        guard let before = toggle.value as? String else {
            XCTFail("\(toggle.identifier) has no value to flip", file: file, line: line)
            return
        }
        if toggle.isHittable {
            // The middle of the switch, which sits at the trailing edge whether the frame is the
            // whole labelled row or the switch alone.
            let dx = max(0.5, 1 - 31.5 / toggle.frame.width)
            toggle.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).press(forDuration: 0.2)
        } else {
            // Under the keyboard, say. The element's own press scrolls it clear first, and a
            // press at a coordinate would land on whatever is covering it.
            toggle.press(forDuration: 0.2)
        }
        let flipped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", before), object: toggle)
        if XCTWaiter().wait(for: [flipped], timeout: timeout) != .completed {
            XCTFail("\(toggle.identifier) was still \(before) after a press", file: file, line: line)
        }
    }
}
