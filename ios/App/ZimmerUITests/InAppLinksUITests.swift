import XCTest

/// A link to one of this Zimmer's own pages, tapped in a transcript, opens the app's screen for
/// it rather than the web UI in a browser. Against the `-ZimmerFixture` in-memory Zimmer: the
/// router (1040) reports the session it spawned as a full URL on the fixture's own deployment,
/// as agents write them, beside a link to GitHub.
@MainActor
final class InAppLinksUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_session_link_in_a_transcript_opens_the_session_here() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1040"])
        XCTAssertTrue(app.navigationBars["#1040"].waitForExistence(timeout: timeout))
        let paragraph = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "markdown.links", "/sessions/1044"))
            .firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: timeout), "the router's report links the session it spawned")
        scrollUntilHittable(app, paragraph)
        attachScreenshot(app, named: "in-app-link-before")

        let link = app.links.matching(NSPredicate(format: "label CONTAINS %@", "/sessions/1044")).firstMatch
        if link.waitForExistence(timeout: 3) {
            link.tap()
        } else {
            // A Text's links are not always their own accessibility elements; the paragraph's
            // long-press menu opens the same link through the same handler. The Zimmer link
            // comes first in the paragraph, so its Open Link is the first.
            paragraph.press(forDuration: 1.5)
            let open = app.buttons["Open Link"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: timeout))
            open.tap()
        }

        XCTAssertTrue(app.navigationBars["#1044"].waitForExistence(timeout: timeout), "the linked session opens in the app")
        XCTAssertEqual(app.state, .runningForeground, "and the app stays in front: no browser took the link")
        attachScreenshot(app, named: "in-app-link-after")

        // Pushed over the page the link was on, so Back returns to it.
        app.navigationBars["#1044"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["#1040"].waitForExistence(timeout: timeout), "Back returns to the transcript")
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    /// The page opens at its newest message; swipe toward `element` until it can be tapped,
    /// below the navigation bar and the section strip pinned under it.
    private func scrollUntilHittable(_ app: XCUIApplication, _ element: XCUIElement) {
        func inView() -> Bool {
            guard element.exists, !element.frame.isEmpty, element.isHittable else { return false }
            let bar = app.navigationBars.firstMatch
            let strip = app.descendants(matching: .any)["detail.sections"]
            let field = app.descendants(matching: .any)["followup.field"]
            let bottom = field.exists ? field.frame.minY - 50 : app.frame.maxY
            return element.frame.minY >= max(bar.exists ? bar.frame.maxY : 0, strip.exists ? strip.frame.maxY : 0)
                && element.frame.maxY <= bottom
        }
        for _ in 0..<8 where !inView() {
            if element.frame.midY < app.frame.midY { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Beside the result bundle too, where a pull request can take it from the artifact.
        if let directory = ProcessInfo.processInfo.environment["ZIMMER_UI_TEST_ARTIFACTS"], !directory.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("test-\(name).png"))
        }
    }
}
