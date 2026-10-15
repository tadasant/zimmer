import XCTest

/// Why a session is waiting, and the one thing to do about it, against the `-ZimmerFixture`
/// in-memory Zimmer: the sweep (1031) is held by the spot gate, the changelog (1029) is
/// queued for a worker while the CarPlay session (1042) holds one, and the Postgres question
/// (1035) has a renewed MCP grant to reconnect and a message that was never delivered.
@MainActor
final class WaitingUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_spot_held_session_is_made_priority_from_its_banner() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1031"])
        let banner = app.descendants(matching: .any)["waiting.banner.spot_hold"]
        XCTAssertTrue(banner.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Held for quota headroom"].exists)
        attachScreenshot(app, named: "spot-hold")

        // The rest of the explanation is one tap away.
        app.buttons["waiting.more.spot_hold"].tap()
        XCTAssertTrue(app.staticTexts["The gate checks again in about 6 minutes."].waitForExistence(timeout: timeout))

        app.buttons["waiting.action.spot_hold"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["followup.notice"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForDisappearance(banner), "a priority session is no longer held")
        let status = app.descendants(matching: .any)["detail.status"]
        XCTAssertTrue(waitForLabelContaining(status, "Running"), "promoting a waiting session starts it")
    }

    func test_a_queued_turn_is_forced_after_confirming_whose_turn_stops() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1029"])
        let banner = app.descendants(matching: .any)["waiting.banner.queued_turn"]
        XCTAssertTrue(banner.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "queued-turn")

        app.buttons["waiting.action.queued_turn"].tap()
        // The web page's confirmation, naming the turn that stops.
        // In the sheet, by its label: a confirmation's identifier does not reach the sheet.
        let confirm = app.sheets.buttons["Force"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Stop session #1042's turn")).firstMatch.exists)
        confirm.tap()

        let notice = app.descendants(matching: .any)["followup.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: timeout))
        XCTAssertTrue(notice.label.contains("put back in the queue"), "the server's sentence about the stopped turn")
        XCTAssertTrue(waitForDisappearance(banner), "the turn has its thread")
    }

    func test_the_reconnect_message_is_sent_and_undelivered_messages_are_listed() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1035"])
        let banner = app.descendants(matching: .any)["waiting.banner.mcp_oauth_reconnect"]
        XCTAssertTrue(banner.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["undelivered.list"].waitForExistence(timeout: timeout), "read-only, as on the web")
        XCTAssertTrue(app.descendants(matching: .any)["undelivered.message.497"].exists)

        // The page opens at the newest message; the banner is at the top.
        let reconnect = app.buttons["waiting.action.mcp_oauth_reconnect"]
        // isHittable says yes while the button is still under the navigation bar, where a tap
        // lands on the bar (a CI recording shows it): scroll until it is below the bar, and below
        // the section strip pinned under it.
        func belowTheBar() -> Bool {
            guard reconnect.exists, !reconnect.frame.isEmpty else { return false }
            let bar = app.navigationBars.firstMatch
            let strip = app.descendants(matching: .any)["detail.sections"]
            let top = max(bar.exists ? bar.frame.maxY : 0, strip.exists ? strip.frame.maxY : 0)
            return reconnect.frame.minY >= top && app.frame.contains(CGPoint(x: reconnect.frame.midX, y: reconnect.frame.maxY))
        }
        for _ in 0..<6 where !belowTheBar() { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(belowTheBar(), "the banner is scrolled into view")
        reconnect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["followup.notice"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForDisappearance(banner), "the message reached the agent, which loads the grant")
    }

    // MARK: - Helpers

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
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

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
