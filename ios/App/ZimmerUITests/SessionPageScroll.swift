import XCTest

extension XCTestCase {
    /// Scroll the session page until `element` sits where a tap reaches it: hittable, below the
    /// navigation bar and the section strip pinned under it (isHittable says yes under them, where
    /// a tap lands on them), and above the composer and its quick replies (which isHittable can
    /// also miss). The session-page tests in `SessionDetailPanelsUITests`,
    /// `TranscriptParityUITests`, `InAppLinksUITests` and `SessionParityUITests` scroll through
    /// here.
    ///
    /// Each step is a drag, held at its end so the page does not fling on, that moves the
    /// element's middle toward the window's middle by at most 30% of the screen. A swipe
    /// (`swipeUp(velocity: .slow)`) is not: it flings, and moves the page further than the window
    /// between the strip and the composer. On main's run 44248595370 (session-page shard) that
    /// made the "said in #1040" row a two-step cycle: one swipe up left it just under the section
    /// strip, the swipe down that followed took it off the bottom of the screen, the next swipe up
    /// put it back under the strip, and eight swipes later it had never been in view. A step
    /// aimed at the window's middle and no longer than the distance to it cannot carry an element
    /// past the window, whatever the element's height.
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
        func inView(_ top: CGFloat, _ bottom: CGFloat) -> Bool {
            guard element.exists, !element.frame.isEmpty, element.isHittable else { return false }
            return element.frame.minY >= top && element.frame.maxY <= bottom
        }
        // Sixteen steps of up to 30% of the screen is about the travel of eight slow swipes.
        for _ in 0..<16 {
            let (top, bottom) = window()
            if inView(top, bottom) { break }
            let frame = element.exists ? element.frame : .zero
            let most = app.frame.height * 0.3
            // Positive moves the page down, bringing what is above into view. Not laid out yet
            // means above: the page opens at its newest message, under the panels.
            var shift = frame.isEmpty ? most : max(-most, min(most, (top + bottom) / 2 - frame.midY))
            // Under the touch slop a drag lands as a tap, on whatever is under its start.
            if abs(shift) < 40 { shift = shift < 0 ? -40 : 40 }
            // Centred on the screen, so the drag stays clear of the strip, the composer and the
            // Quick Router button at the bottom right.
            let from = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: app.frame.midX, dy: app.frame.midY - shift / 2))
            from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: shift)),
                       withVelocity: .default, thenHoldForDuration: 0.3)
        }
        let (top, bottom) = window()
        XCTAssertTrue(inView(top, bottom), "\(element) comes into view", file: file, line: line)
    }
}
