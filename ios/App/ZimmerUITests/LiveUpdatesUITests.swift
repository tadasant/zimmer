import XCTest

/// The session page reads again on its own, opens on its summary with the transcript's newest
/// message a tap away, and keeps what you typed — against the `-ZimmerFixture` in-memory Zimmer.
@MainActor
final class LiveUpdatesUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_running_session_shows_new_messages_without_a_pull() throws {
        // -ZimmerFixtureLive: the running session's agent adds a line on each read after the first.
        let app = launch(["-ZimmerFixtureLive", "-ZimmerFixtureOpenSession", "1042"])
        XCTAssertTrue(app.descendants(matching: .any)["followup.field"].waitForExistence(timeout: timeout))
        let newLine = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Still working — step 1 done.")).firstMatch
        XCTAssertTrue(newLine.waitForExistence(timeout: timeout), "a new message appears with nothing touched")
    }

    func test_reading_back_is_not_pulled_to_the_end_by_new_messages() throws {
        let app = launch(["-ZimmerFixtureLive", "-ZimmerFixtureOpenSession", "1042"])
        let first = app.descendants(matching: .any)["detail.message.0"]
        XCTAssertTrue(first.waitForExistence(timeout: timeout))
        // From the newest message, reading back up.
        let chip = app.buttons["detail.sections.transcript"]
        if chip.waitForExistence(timeout: timeout) { chip.tap() }
        // Swiping only once the chip's scroll has landed on the newest message, or the two fight.
        let messages = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'detail.message.'"))
        let newest = messages.element(boundBy: messages.count - 1)
        let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: newest)
        XCTAssertEqual(XCTWaiter().wait(for: [landed], timeout: timeout), .completed, "the chip lands on the newest message")
        for _ in 0..<8 where !first.isHittable { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(first.isHittable, "scrolled back to the start")
        // Two polls' worth of new lines arrive while reading back.
        let later = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "step 2 done")).firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: timeout))
        XCTAssertTrue(first.isHittable, "still where the reader left it")
    }

    func test_the_transcript_opens_at_its_newest_message() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1044"])
        let summary = app.descendants(matching: .any)["detail.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: timeout), "the page opens on its summary")
        let newest = app.descendants(matching: .any)["detail.message.6"]
        XCTAssertTrue(newest.waitForExistence(timeout: timeout))
        let chip = app.buttons["detail.sections.transcript"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))
        chip.tap()
        let field = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        // Its end above the composer, not under it: polled, as the scroll settles.
        let deadline = Date().addingTimeInterval(timeout)
        var landed = false
        while !landed, Date() < deadline {
            landed = newest.exists && newest.isHittable && newest.frame.maxY <= field.frame.minY + 1
            if !landed { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        }
        XCTAssertTrue(landed, "the newest message is in view, above the composer")
    }

    func test_a_draft_survives_leaving_the_session() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1035"])
        let field = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Try 17 on a copy first")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let row = app.descendants(matching: .any)["session.row.1035"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        row.tap()
        let reopened = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(reopened.waitForExistence(timeout: timeout))
        let kept = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Try 17 on a copy first"), object: reopened)
        XCTAssertEqual(XCTWaiter().wait(for: [kept], timeout: timeout), .completed, "the words are still there")
    }

    // MARK: - Helpers

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }
}
