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
        scrollSessionPageUntilHittable(app, paragraph)
        attachScreenshot(app, named: "in-app-link-before")

        // Through the paragraph's long-press menu, whose Open Link goes through the same handler
        // as a tap on the link: a tap at the centre of a URL that wraps can land on the words
        // beside it. The Zimmer link comes first in the paragraph, so its Open Link is the first.
        let open = pressForMenuInPlace(app, paragraph, offering: "Open Link", timeout: timeout)
        XCTAssertTrue(open.exists, "the menu opens the link")
        open.tap()

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
