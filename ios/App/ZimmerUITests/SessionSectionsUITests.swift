import XCTest

/// The session page's pinned section strip and its full-screen transcript, against the
/// `-ZimmerFixture` in-memory Zimmer with 1044's conversation run long: the page opens on its
/// status summary, the transcript's chip lands on the newest message a hundred messages down,
/// and from there the hierarchy and the human messages are still one tap away.
@MainActor
final class SessionSectionsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_session_opens_on_its_summary_and_the_transcript_opens_at_the_newest_message() throws {
        let app = launch()
        let summary = app.descendants(matching: .any)["detail.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: timeout))
        // The whole conversation is read before the page can be said to have opened on top of it.
        let newest = app.descendants(matching: .any)["detail.message.98"]
        XCTAssertTrue(newest.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForVisible(app, summary), "the page opens on where things stand")
        XCTAssertTrue(waitForSelected(app.buttons["detail.sections.overview"]), "at the top, the overview's chip is lit")
        XCTAssertFalse(isInView(app, newest), "a hundred messages down, the newest is out of sight")
        attachScreenshot(app, named: "summary-default")

        // One tap on the transcript's chip: its newest message, at the foot of what is in view.
        app.buttons["detail.sections.transcript"].tap()
        XCTAssertTrue(waitForFootInView(app, newest), "the transcript opens at its newest message")
        XCTAssertTrue(waitForSelected(app.buttons["detail.sections.transcript"]))
        attachScreenshot(app, named: "transcript-newest")
    }

    /// The strip's down arrow: from the top of the page, and from a section far above the end,
    /// one tap lands on the newest message.
    func test_the_strips_arrow_jumps_to_the_newest_message_from_anywhere_on_the_page() throws {
        let app = launch()
        let latest = app.buttons["detail.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: timeout))
        XCTAssertEqual(latest.label, "Jump to the newest message")
        let newest = app.descendants(matching: .any)["detail.message.98"]
        XCTAssertTrue(newest.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForVisible(app, app.descendants(matching: .any)["detail.summary"]), "the page opens on its summary")
        XCTAssertFalse(isInView(app, newest), "a hundred messages down, the newest is out of sight")
        XCTAssertTrue(latest.isHittable, "the arrow is at the top of the page, in the pinned strip")
        attachScreenshot(app, named: "latest-arrow")

        latest.tap()
        XCTAssertTrue(waitForFootInView(app, newest), "the arrow lands on the newest message")
        XCTAssertTrue(waitForSelected(app.buttons["detail.sections.transcript"]), "at the newest message, the transcript's chip is lit")
        attachScreenshot(app, named: "latest-arrow-landed")

        // Away to the hierarchy, and back down in one tap: the strip stays pinned.
        app.buttons["detail.sections.hierarchy"].tap()
        let origin = app.descendants(matching: .any)["hierarchy.node.1040"]
        XCTAssertTrue(origin.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForVisible(app, origin))
        XCTAssertFalse(isInView(app, newest), "the hierarchy is far above the newest message")
        XCTAssertTrue(latest.isHittable)
        latest.tap()
        XCTAssertTrue(waitForFootInView(app, newest), "and again from the hierarchy")
    }

    func test_the_summarys_newest_message_button_opens_the_transcript_at_its_end() throws {
        let app = launch()
        let button = app.buttons["detail.summary.transcript"]
        XCTAssertTrue(button.waitForExistence(timeout: timeout))
        let newest = app.descendants(matching: .any)["detail.message.98"]
        XCTAssertTrue(newest.waitForExistence(timeout: timeout))
        button.tap()
        XCTAssertTrue(waitForFootInView(app, newest), "the button lands on the newest message")
    }

    /// 1048 has no summary yet: the card says so, rather than the page opening on the details,
    /// and its button reads the transcript from its newest message.
    func test_a_session_without_a_summary_says_so_and_offers_the_transcript() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1048"])
        let empty = app.descendants(matching: .any)["detail.summary.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForVisible(app, empty), "the page opens on the summary's place")
        attachScreenshot(app, named: "summary-none")
        let button = app.buttons["detail.summary.transcript"]
        XCTAssertTrue(button.waitForExistence(timeout: timeout))
        button.tap()
        XCTAssertTrue(waitForFootInView(app, app.descendants(matching: .any)["detail.message.1"]), "the newest message, its end in view")
    }

    func test_the_strip_reaches_the_human_messages_and_the_hierarchy_from_the_end_of_a_long_transcript() throws {
        let app = launch()
        let strip = app.descendants(matching: .any)["detail.sections"]
        XCTAssertTrue(strip.waitForExistence(timeout: timeout))
        let newest = app.descendants(matching: .any)["detail.message.98"]
        XCTAssertTrue(newest.waitForExistence(timeout: timeout))
        app.buttons["detail.sections.transcript"].tap()
        XCTAssertTrue(waitForFootInView(app, newest))
        XCTAssertTrue(waitForSelected(app.buttons["detail.sections.transcript"]), "at the newest message, the transcript's chip is lit")
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
        XCTAssertTrue(waitForFootInView(app, newest))
    }

    func test_the_transcript_reads_full_screen_and_goes_back_to_the_page() throws {
        let app = launch()
        let enter = app.buttons["detail.fullscreen"]
        XCTAssertTrue(enter.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["detail.message.98"].waitForExistence(timeout: timeout))
        // From the top of the page, on the summary: the cover opens at the newest message all
        // the same, not at the first of a hundred.
        XCTAssertTrue(waitForVisible(app, app.descendants(matching: .any)["detail.summary"]))
        enter.tap()

        let exit = app.buttons["transcript.fullscreen.exit"]
        XCTAssertTrue(exit.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.navigationBars["#1044 · Transcript"].exists)
        // The page stays under the cover, messages and all: what is read is the cover's own.
        let cover = app.descendants(matching: .any)["transcript.fullscreen.messages"]
        XCTAssertTrue(cover.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForNotHittable(app.buttons["detail.sections.overview"]), "the page's chrome is covered")
        XCTAssertTrue(waitForFootInView(app, cover.descendants(matching: .any)["detail.message.98"]), "opened at the newest message")
        attachScreenshot(app, named: "fullscreen-transcript")

        exit.tap()
        XCTAssertTrue(waitForDisappearance(exit))
        XCTAssertTrue(waitForDisappearance(app.navigationBars["#1044 · Transcript"]))
        XCTAssertTrue(app.descendants(matching: .any)["detail.sections"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.navigationBars["#1044"].exists, "back on the page")
        XCTAssertTrue(waitForFootInView(app, app.descendants(matching: .any)["detail.message.98"]), "where it was left: the newest")
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

    /// The top of what is open: under the navigation bar and the strip.
    private func openTop(_ app: XCUIApplication) -> CGFloat {
        let bar = app.navigationBars.firstMatch
        let strip = app.descendants(matching: .any)["detail.sections"]
        var top = bar.exists ? bar.frame.maxY : 0
        if strip.exists { top = max(top, strip.frame.maxY) }
        return top
    }

    /// The foot of what is open: above the composer when there is one.
    private func openBottom(_ app: XCUIApplication) -> CGFloat {
        let field = app.descendants(matching: .any)["followup.field"]
        return field.exists && !field.frame.isEmpty ? min(app.frame.maxY, field.frame.minY) : app.frame.maxY
    }

    /// Any of `element` in the open part of the screen, now.
    private func isInView(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists, !element.frame.isEmpty else { return false }
        return element.frame.maxY > openTop(app) && element.frame.minY < openBottom(app)
    }

    /// The end of `element` — the newest message, however tall — inside the open part of the
    /// screen: scrolled to the bottom, not to the top of a message whose end is out of sight.
    /// Polled until it holds, so a scroll still settling is waited for rather than timed.
    private func waitForFootInView(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, !element.frame.isEmpty {
                let foot = element.frame.maxY
                if foot > openTop(app), foot <= openBottom(app) + 1 { return true }
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
