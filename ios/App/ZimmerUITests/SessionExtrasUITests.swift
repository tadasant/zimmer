import XCTest

/// Slice 3: a session's queued messages, its logs and its subagents, against the
/// `-ZimmerFixture` in-memory Zimmer, where the running CarPlay session (1042) has two
/// messages queued and one subagent.
@MainActor
final class SessionExtrasUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_queued_message_is_edited_then_deleted_and_the_rest_sent_now() throws {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["detail.queue"].waitForExistence(timeout: timeout))
        let second = app.descendants(matching: .any)["queue.message.502"]
        XCTAssertTrue(second.exists)

        // Edit the first.
        app.buttons["queue.actions.501"].tap()
        app.buttons["Edit"].firstMatch.tap()
        let editor = app.textViews["queue.edit.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: timeout))
        editor.tap()
        editor.typeText(" Please.")
        app.buttons["queue.edit.save"].tap()
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["queue.message.501"], "Please."))

        // Delete the second, after the confirmation the web UI asks for too. The edit made the
        // first longer, which can push the second's button under the composer and its quick
        // replies: above them first.
        let secondActions = app.buttons["queue.actions.502"]
        let composer = app.descendants(matching: .any)["followup.field"]
        for _ in 0..<3 where secondActions.frame.maxY > composer.frame.minY - 60 { app.swipeUp(velocity: .slow) }
        secondActions.tap()
        app.buttons["Delete"].firstMatch.tap()
        let confirmDelete = app.sheets.buttons["Delete"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: timeout))
        confirmDelete.tap()
        XCTAssertTrue(waitForDisappearance(second), "a deleted message leaves the queue")

        // Send the first now: it becomes the next turn, and the queue is empty.
        app.buttons["queue.actions.501"].tap()
        app.buttons["Send Now"].firstMatch.tap()
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["detail.queue"]), "an empty queue hides its panel")
    }

    func test_logs_and_a_subagent_transcript_open_from_the_session_menu() throws {
        let app = launch()
        let actions = app.buttons["detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: timeout))

        actions.tap()
        app.buttons["Show Logs"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["log.104200"].waitForExistence(timeout: timeout))
        app.buttons["Done"].firstMatch.tap()

        actions.tap()
        app.buttons["Subagents"].firstMatch.tap()
        let subagent = app.descendants(matching: .any)["subagent.7"]
        XCTAssertTrue(subagent.waitForExistence(timeout: timeout))
        subagent.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.message.2"].waitForExistence(timeout: timeout), "the subagent's answer is shown")
    }

    func test_an_also_senior_link_is_detached_from_the_hierarchy() throws {
        let app = launch()
        let chip = app.buttons["hierarchy.uncle.1031.1035"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))
        // The page opens on its summary, with the hierarchy's rows low on the screen, under the
        // composer, where a tap lands on the composer: bring the chip into the open part first.
        bringIntoOpen(app, chip)
        chip.tap()
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: timeout))
        remove.tap()
        XCTAssertTrue(waitForDisappearance(chip), "the detached senior's chip is gone")
    }

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureOpenSession", "1042"]
        app.launch()
        return app
    }

    /// Swipes until `element` sits below the bar and the section strip and above the composer
    /// and its quick replies, either way, since it can start under either.
    private func bringIntoOpen(_ app: XCUIApplication, _ element: XCUIElement) {
        func edges() -> (top: CGFloat, bottom: CGFloat) {
            let bar = app.navigationBars.firstMatch
            let strip = app.descendants(matching: .any)["detail.sections"]
            var top = bar.exists ? bar.frame.maxY : 0
            if strip.exists { top = max(top, strip.frame.maxY) }
            var bottom = app.frame.maxY
            let field = app.descendants(matching: .any)["followup.field"]
            if field.exists { bottom = min(bottom, field.frame.minY) }
            let reply = app.buttons["Yes, go ahead."].firstMatch
            if reply.exists { bottom = min(bottom, reply.frame.minY) }
            return (top, bottom)
        }
        for _ in 0..<6 {
            let (top, bottom) = edges()
            let frame = element.frame
            if frame.minY >= top, frame.maxY <= bottom { return }
            if frame.maxY > bottom { app.swipeUp(velocity: .slow) } else { app.swipeDown(velocity: .slow) }
        }
        let (top, bottom) = edges()
        XCTAssertTrue(element.frame.minY >= top && element.frame.maxY <= bottom, "\(element) is in the open part of the page")
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }
}
