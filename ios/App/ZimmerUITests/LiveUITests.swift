import XCTest

/// Live Mode and Live Voice, against the `-ZimmerFixture` in-memory Zimmer: the session list's
/// waveform button opens Live, a Live Mode conversation is started and typed into and answered,
/// and a Live Voice thread shows what was said and the call controls. A real call needs a
/// microphone and OpenAI, neither of which a simulator run has; the call's protocol logic is
/// `RealtimeConductor`, tested in ZimmerKit.
@MainActor
final class LiveUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_live_mode_is_entered_from_the_main_screen_typed_into_and_ended() throws {
        let app = launch()
        let open = app.buttons["live.open"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout), "the waveform button is on the session list")
        open.tap()

        XCTAssertTrue(app.descendants(matching: .any)["live.mode.voice"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["live.mode.text"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["live.resume.voice"].exists, "the open Live Voice conversation can be resumed")
        attachScreenshot(app, named: "live-home")

        let start = app.descendants(matching: .any)["live.start.text"].firstMatch
        start.tap()
        let composer = app.descendants(matching: .any)["live.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: timeout), "a new Live Mode conversation opens with its composer")
        composer.tap()
        composer.typeText("Please look into the flaky poller test")
        app.buttons["live.send"].tap()

        XCTAssertTrue(labelled(app, "Please look into the flaky poller test").waitForExistence(timeout: timeout), "what was typed is in the thread")
        XCTAssertTrue(labelled(app, "quick_router").waitForExistence(timeout: timeout), "the delegation shows as a tool line")
        XCTAssertTrue(labelled(app, "Started a session on that").waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "live-mode-thread")

        app.buttons["live.conversation.menu"].tap()
        app.buttons["End conversation"].tap()
        XCTAssertTrue(waitForGone(app.descendants(matching: .any)["live.composer"].firstMatch), "an ended conversation takes no more messages")
    }

    func test_a_live_voice_thread_shows_what_was_said_and_the_call_controls() throws {
        let app = launch(["-ZimmerFixtureLiveConversation", "21"])
        XCTAssertTrue(labelled(app, "Is the flaky poller test still failing on main?").waitForExistence(timeout: timeout))
        XCTAssertTrue(labelled(app, "quick_router").exists)
        XCTAssertTrue(app.buttons["live.talk"].exists, "Talk starts the call")
        attachScreenshot(app, named: "live-voice-thread")
    }

    func test_the_gear_on_a_conversation_opens_the_live_settings() throws {
        let app = launch(["-ZimmerFixtureLiveConversation", "21"])
        XCTAssertTrue(labelled(app, "Is the flaky poller test still failing on main?").waitForExistence(timeout: timeout))
        let gear = app.buttons["live-settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: timeout), "the gear is on the conversation's toolbar")
        gear.tap()

        XCTAssertTrue(app.descendants(matching: .any)["live-settings-view"].firstMatch.waitForExistence(timeout: timeout))
        XCTAssertTrue(labelled(app, "Speaking speed").waitForExistence(timeout: timeout), "each field is listed")
        attachScreenshot(app, named: "live-settings")

        app.buttons["live-settings.done"].tap()
        XCTAssertTrue(waitForGone(app.descendants(matching: .any)["live-settings-view"].firstMatch))
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    /// The first element whose label contains `text`, whatever kind of element SwiftUI made it.
    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func waitForGone(_ element: XCUIElement) -> Bool {
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
