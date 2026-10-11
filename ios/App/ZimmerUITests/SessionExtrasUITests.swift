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

        // Delete the second.
        app.buttons["queue.actions.502"].tap()
        app.buttons["Delete"].firstMatch.tap()
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

    // MARK: - Helpers

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureOpenSession", "1042"]
        app.launch()
        return app
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
