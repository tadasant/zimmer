import XCTest

/// Slice 6: answering an MCP server's prompt and forking at a message, against the
/// `-ZimmerFixture` in-memory Zimmer, where the staging session (1035) is stopped on a
/// migration prompt.
@MainActor
final class InteractionUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_prompt_refuses_an_empty_required_field_then_is_accepted() throws {
        let app = launch(1035)
        let card = app.buttons["prompt.71"]
        XCTAssertTrue(card.waitForExistence(timeout: timeout))
        card.tap()

        let accept = app.buttons["prompt.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: timeout))
        accept.tap()
        let refusal = app.descendants(matching: .any)["prompt.refusal"]
        XCTAssertTrue(refusal.waitForExistence(timeout: timeout), "Database is required")

        let database = app.buttons["prompt.field.database"].exists
            ? app.buttons["prompt.field.database"]
            : app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Database'")).firstMatch
        database.tap()
        app.buttons["staging"].firstMatch.tap()
        let batch = app.textFields["prompt.field.batch_size"]
        batch.tap()
        batch.typeText("500")
        accept.tap()

        XCTAssertTrue(waitForDisappearance(card), "an answered prompt leaves the session")
    }

    func test_a_prompt_is_dismissed_without_answering() throws {
        let app = launch(1035)
        let card = app.buttons["prompt.71"]
        XCTAssertTrue(card.waitForExistence(timeout: timeout))
        card.tap()
        let dismiss = app.buttons["prompt.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: timeout))
        dismiss.tap()
        XCTAssertTrue(waitForDisappearance(card))
    }

    func test_forking_at_a_message_opens_the_fork() throws {
        let app = launch(1038)
        // Message 0 is the person's request; 1 is a tool call, hidden by default; 2 is the answer.
        let message = app.descendants(matching: .any)["detail.message.0"]
        XCTAssertTrue(message.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["detail.message.2"].exists)
        // Below the session's cards the conversation starts under the composer, where an
        // element still reads as hittable: scroll until it is clear of the message field.
        let field = app.descendants(matching: .any)["followup.field"]
        for _ in 0..<6 where message.frame.maxY > field.frame.minY - 24 { app.swipeUp() }
        message.press(forDuration: 1.0)
        let fork = app.buttons["Fork from Here"].firstMatch
        XCTAssertTrue(fork.waitForExistence(timeout: timeout))
        fork.tap()
        let confirm = app.buttons["Fork"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()

        // The fork opens on top: its own number, and the conversation up to the message.
        XCTAssertTrue(app.navigationBars["#1043"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["detail.message.2"]), "nothing after the fork point")
        XCTAssertTrue(app.descendants(matching: .any)["detail.message.0"].exists)
    }

    // MARK: - Helpers

    private func launch(_ session: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureOpenSession", String(session)]
        app.launch()
        return app
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
