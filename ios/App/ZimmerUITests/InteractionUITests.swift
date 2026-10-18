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
        let accept = app.buttons["prompt.accept"]
        XCTAssertTrue(openPrompt(app, card, showing: accept))
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
        let dismiss = app.buttons["prompt.dismiss"]
        XCTAssertTrue(openPrompt(app, card, showing: dismiss))
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

        // The fork opens on top — its title says what it was forked from, whatever number the
        // fixture gives it — holding the conversation up to the message.
        let forkTitle = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Fork of '")).firstMatch
        XCTAssertTrue(forkTitle.waitForExistence(timeout: timeout))
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

    /// The prompt's sheet, opened from its card, until `control` in it is on screen.
    ///
    /// The card sits above the conversation, and the page opens at the newest message on a
    /// later turn than the one that lays the conversation out. A tap that lands as that scroll
    /// moves the page opens nothing — run 39091739178's recording shows the page jumping to the
    /// transcript under the tap and no sheet. So the conversation is waited for (the scroll
    /// follows on the next turn), the page is scrolled back until the card is clear of the bar,
    /// the section strip and the composer (that run's log shows XCUITest tapping where the card
    /// was, without scrolling to it), and a tap that brought no sheet taps again; never while
    /// the sheet is up, where the card's point is somewhere in the form.
    private func openPrompt(_ app: XCUIApplication, _ card: XCUIElement, showing control: XCUIElement) -> Bool {
        XCTAssertTrue(card.waitForExistence(timeout: timeout))
        let message = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'detail.message.'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: timeout), "the conversation is on the page")
        let sheet = app.navigationBars["Approval Needed"]
        let attempts = 3
        for attempt in 0..<attempts {
            if !sheet.exists {
                for _ in 0..<4 where !clear(app, card) { app.swipeDown(velocity: .slow) }
                card.tap()
            }
            if control.waitForExistence(timeout: attempt == attempts - 1 ? timeout : 5) { return true }
        }
        return false
    }

    /// On screen, between what covers the top of the page and the composer at its foot.
    private func clear(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let bar = app.navigationBars.firstMatch
        let strip = app.descendants(matching: .any)["detail.sections"]
        var top = bar.exists ? bar.frame.maxY : 0
        if strip.exists { top = max(top, strip.frame.maxY) }
        let field = app.descendants(matching: .any)["followup.field"]
        let bottom = field.exists ? field.frame.minY : app.frame.maxY
        return element.frame.minY >= top - 1 && element.frame.maxY <= bottom
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
