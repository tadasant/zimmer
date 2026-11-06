import XCTest

/// A call the car leaves on the phone: the phone goes to it, unless the person is busy, the call
/// has ended, or the car came back. `-ZimmerFixtureCarScript` plays the car's moves through the
/// same calls the CarPlay scene makes, on a call held on Connecting…; the Simulator's real
/// disconnect is the CarPlay drill's, and it can be had only once per process.
@MainActor
final class LiveHandoverUITests: XCTestCase {
    private let timeout: TimeInterval = 20
    /// Long enough for any landing to have happened: the settle, a turn of the watch, and a sheet.
    private let wellPastTheSettle: TimeInterval = 7

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_with_the_app_open_the_phone_lands_on_the_call() {
        let app = launch(["-ZimmerFixtureCarScript", "left@2"])
        XCTAssertTrue(callState(app).waitForExistence(timeout: timeout), "the phone goes to the call")
        XCTAssertTrue(app.buttons["live.talk"].exists, "with its Hang up to hand")
        XCTAssertTrue(app.buttons["live.mute"].exists, "and Mute")
        attachScreenshot(app, named: "live-handover-landed")
    }

    func test_with_the_app_in_the_background_it_lands_on_the_next_foreground() {
        let app = launch(["-ZimmerFixtureCarScript", "left@6"])
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 12)
        app.activate()
        XCTAssertTrue(callState(app).waitForExistence(timeout: timeout), "the wait ends at the next foreground")
        attachScreenshot(app, named: "live-handover-next-foreground")
    }

    func test_a_call_that_ended_in_the_pocket_leaves_the_phone_where_it_was() {
        let app = launch(["-ZimmerFixtureCarScript", "left@6,end@8"])
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 12)
        app.activate()
        XCTAssertTrue(board(app).waitForExistence(timeout: timeout))
        assertStaysOnTheBoard(app, "the call is over, so Live is not opened")
    }

    func test_a_car_that_came_back_leaves_the_phone_where_it_was() {
        let app = launch(["-ZimmerFixtureCarScript", "left@2,back@3"])
        XCTAssertTrue(board(app).waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 3)
        assertStaysOnTheBoard(app, "the blip passed")
    }

    func test_a_flap_lands_once_for_the_last_disconnect_and_only_after_it_settles() {
        let app = launch(["-ZimmerFixtureCarScript", "left@2,back@3,left@4,back@5,left@6"])
        XCTAssertTrue(callState(app).waitForExistence(timeout: timeout), "the car stayed gone, so the phone goes to the call")
        XCTAssertEqual(app.navigationBars.matching(identifier: "Live Mode").count, 1, "one thread, not one for each disconnect")
    }

    func test_an_open_sheet_keeps_its_words_and_the_phone_lands_when_it_closes() {
        let app = launch(["-ZimmerFixtureQuickRouter", "-ZimmerFixtureCarScript", "left@6"])
        let field = app.descendants(matching: .any)["quickrouter.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("half a thought")
        Thread.sleep(forTimeInterval: wellPastTheSettle + 2)

        XCTAssertFalse(callState(app).exists, "nothing is presented over the sheet")
        XCTAssertEqual(field.value as? String, "half a thought", "and nothing is lost")
        attachScreenshot(app, named: "live-handover-held-by-a-sheet")

        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(callState(app).waitForExistence(timeout: timeout), "closing it lets the phone go to the call")
    }

    func test_a_sheet_the_model_does_not_know_about_holds_it_too() {
        let app = launch(["-ZimmerFixtureOpenSession", "2", "-ZimmerFixtureCustomSnooze", "-ZimmerFixtureCarScript", "left@8"])
        let picker = app.descendants(matching: .any)["snooze.custom.picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 8 + wellPastTheSettle)
        XCTAssertTrue(picker.exists, "the session page's own sheet stays up")
        XCTAssertFalse(callState(app).exists)
    }

    // MARK: - Helpers

    private func callState(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["live.call.state"].firstMatch
    }

    private func board(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["live.open"]
    }

    private func assertStaysOnTheBoard(_ app: XCUIApplication, _ why: String) {
        Thread.sleep(forTimeInterval: wellPastTheSettle)
        XCTAssertFalse(callState(app).exists, why)
        XCTAssertFalse(app.buttons["live.done"].exists, why)
        XCTAssertTrue(board(app).isHittable, why)
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
