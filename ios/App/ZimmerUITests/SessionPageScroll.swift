import XCTest

extension XCTestCase {
    /// Scroll the session page until `element` sits where a tap reaches it: hittable, below the
    /// navigation bar and the section strip pinned under it (isHittable says yes under them, where
    /// a tap lands on them), and above the composer and its quick replies (which isHittable can
    /// also miss). Every session-page UI test scrolls through here.
    ///
    /// Each step is a third of the screen, held at the end so there is no fling, the way
    /// `SettingsUITests` and `AccountUITests` scroll. A swipe (`swipeUp(velocity: .slow)`) is
    /// not: it flings, and moves the page further than the window between the strip and the
    /// composer. On main's run 44248595370 (session-page shard) that made the "said in #1040" row
    /// a two-step cycle: one swipe up left it just under the section strip, the swipe down that
    /// followed took it off the bottom of the screen, the next swipe up put it back under the
    /// strip, and eight swipes later it had never been in view. A third of a screen is well under
    /// that window, so a step cannot carry an element from one side of it to the other.
    @MainActor
    func scrollSessionPageUntilHittable(
        _ app: XCUIApplication, _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        let bar = app.navigationBars.firstMatch
        let strip = app.descendants(matching: .any)["detail.sections"]
        let field = app.descendants(matching: .any)["followup.field"]
        func window() -> (top: CGFloat, bottom: CGFloat) {
            let top = max(bar.exists ? bar.frame.maxY : 0, strip.exists ? strip.frame.maxY : 0)
            let bottom = field.exists ? field.frame.minY - 50 : app.frame.maxY
            return (top, bottom)
        }
        // Ask for hittability only of an element on the page with a frame: asking it of one the
        // lazy list has not laid out throws rather than answering no.
        func inView() -> Bool {
            guard element.exists, !element.frame.isEmpty, element.isHittable else { return false }
            let (top, bottom) = window()
            return element.frame.minY >= top && element.frame.maxY <= bottom
        }
        // `break`, not `where !inView()`: a `where` asks every time even once it is in view, and
        // each ask is several queries. Sixteen thirds of a screen is about the travel of the
        // eight swipes this replaced.
        for _ in 0..<16 {
            if inView() { break }
            let frame = element.exists ? element.frame : .zero
            // Not laid out yet means above: the page opens at its newest message, under the panels.
            let (top, bottom) = window()
            let towardTop = frame.isEmpty || frame.midY < (top + bottom) / 2
            // The finger moves down to bring what is above into view, up for what is below. It
            // starts and ends in the middle of the page, clear of the strip, the composer and
            // the Quick Router button at the bottom right.
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.45 : 0.75))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.75 : 0.45))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(inView(), "\(element) comes into view", file: file, line: line)
    }
}
