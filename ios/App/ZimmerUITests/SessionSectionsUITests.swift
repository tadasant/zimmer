import XCTest

/// The session page's pinned section strip and its full-screen transcript, against the
/// `-ZimmerFixture` in-memory Zimmer with 1044's conversation run long: the page opens at the
/// newest message, a hundred messages under the details card, and the hierarchy and the human
/// messages are still one tap away.
@MainActor
final class SessionSectionsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_strip_reaches_the_human_messages_and_the_hierarchy_from_the_end_of_a_long_transcript() throws {
        let app = launch()
        let strip = app.descendants(matching: .any)["detail.sections"]
        XCTAssertTrue(strip.waitForExistence(timeout: timeout))
        let newest = app.descendants(matching: .any)["detail.message.98"]
        XCTAssertTrue(newest.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForSelected(app.buttons["detail.sections.transcript"]), "opened at the newest message, the transcript's chip is lit")
        let summary = labelled(app, "1 message in this session · 1 elsewhere")
        XCTAssertFalse(summary.exists && summary.isHittable, "a hundred messages down, the human messages are out of sight")
        attachScreenshot(app, named: "sections-long-transcript")

        // One tap: the human messages under the strip, opened.
        app.buttons["detail.sections.humanMessages"].tap()
        let here = app.descendants(matching: .any)["humanmessage.here"]
        XCTAssertTrue(here.waitForExistence(timeout: timeout), "the folded row opens as the strip jumps to it")
        XCTAssertTrue(waitForVisible(app, labelled(app, "1 message in this session · 1 elsewhere")))
        XCTAssertTrue(waitForSelected(app.buttons["detail.sections.humanMessages"]))
        XCTAssertTrue(app.buttons["detail.sections.overview"].isHittable, "the strip stays pinned")
        attachScreenshot(app, named: "sections-human-messages")

        // One tap: the hierarchy, its seven sessions opened.
        app.buttons["detail.sections.hierarchy"].tap()
        let origin = app.descendants(matching: .any)["hierarchy.node.1040"]
        XCTAssertTrue(origin.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForVisible(app, origin))
        XCTAssertTrue(waitForSelected(app.buttons["detail.sections.hierarchy"]))
        attachScreenshot(app, named: "sections-hierarchy")

        // And back to the newest message.
        app.buttons["detail.sections.transcript"].tap()
        XCTAssertTrue(waitForVisible(app, newest))
    }

    func test_the_transcript_reads_full_screen_and_goes_back_to_the_page() throws {
        let app = launch()
        let enter = app.buttons["detail.fullscreen"]
        XCTAssertTrue(enter.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["detail.message.98"].waitForExistence(timeout: timeout))
        enter.tap()

        let exit = app.buttons["transcript.fullscreen.exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.navigationBars["#1044 · Transcript"].exists)
        // The page stays under the cover, messages and all: what is read is the cover's own.
        let cover = app.descendants(matching: .any)["transcript.fullscreen.messages"]
        XCTAssertTrue(cover.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForNotHittable(app.buttons["detail.sections.overview"]), "the page's chrome is covered")
        XCTAssertTrue(waitForVisible(app, cover.descendants(matching: .any)["detail.message.98"]), "opened at the newest message")
        attachScreenshot(app, named: "fullscreen-transcript")

        exit.tap()
        XCTAssertTrue(waitForDisappearance(exit))
        XCTAssertTrue(waitForDisappearance(app.navigationBars["#1044 · Transcript"]))
        XCTAssertTrue(app.descendants(matching: .any)["detail.sections"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.navigationBars["#1044"].exists, "back on the page")
        XCTAssertTrue(waitForVisible(app, app.descendants(matching: .any)["detail.message.98"]), "where it was left")
        attachScreenshot(app, named: "fullscreen-exited")
    }

    func test_the_full_screen_transcript_keeps_reading_new_messages() throws {
        // -ZimmerFixtureLive: the running session's agent adds a line on each read after the first.
        let app = launch(["-ZimmerFixtureLive", "-ZimmerFixtureOpenSession", "1042"])
        let enter = app.buttons["detail.fullscreen"]
        XCTAssertTrue(enter.waitForExistence(timeout: timeout))
        enter.tap()
        XCTAssertTrue(app.buttons["transcript.fullscreen.exit"].waitForExistence(timeout: timeout))
        let cover = app.descendants(matching: .any)["transcript.fullscreen.messages"]
        XCTAssertTrue(cover.waitForExistence(timeout: timeout))
        // The page stands its reads down while covered: these come from the cover's own.
        let later = cover.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "step 2 done")).firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: 30), "a new message appears full screen with nothing touched")
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String] = ["-ZimmerFixtureLongTranscript", "-ZimmerFixtureOpenSession", "1044"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// On screen, and not under the bars: the strip's jump put it there.
    private func waitForVisible(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, !element.frame.isEmpty {
                let bar = app.navigationBars.firstMatch
                let strip = app.descendants(matching: .any)["detail.sections"]
                var top = bar.exists ? bar.frame.maxY : 0
                if strip.exists { top = max(top, strip.frame.maxY) }
                if element.frame.minY >= top - 1, element.frame.minY < app.frame.maxY { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func waitForNotHittable(_ element: XCUIElement) -> Bool {
        let covered = expectation(for: NSPredicate(format: "hittable == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [covered], timeout: timeout) == .completed
    }

    private func waitForSelected(_ element: XCUIElement) -> Bool {
        let selected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [selected], timeout: timeout) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
