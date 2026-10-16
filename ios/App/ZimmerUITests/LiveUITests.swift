import XCTest

/// Live Mode, against the `-ZimmerFixture` in-memory Zimmer: the session list's waveform button
/// lands in the open conversation with voice on (a new one with voice on when none is open), one
/// tap turns voice off in that same thread and two start a new one; Back leads to the Live list,
/// where one conversation is started and typed into and answered with Enable voice beside the
/// composer; and a thread with voice on shows what was said, the call controls and Type instead.
/// A real call needs a microphone and OpenAI, neither of which a simulator run has, so a fixture
/// landing turns voice on without starting the call; the call's protocol logic is
/// `RealtimeConductor`, tested in ZimmerKit.
@MainActor
final class LiveUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_live_button_lands_in_the_open_conversation_with_voice_on_one_tap_types_and_two_start_new() throws {
        let app = launch()
        openLive(app)
        let spoken = labelled(app, "Is the flaky poller test still failing on main?")
        XCTAssertTrue(spoken.waitForExistence(timeout: timeout), "the waveform button lands in the open conversation")
        // The fixture's open conversation is spoken already; the next test lands in a typed one.
        XCTAssertTrue(element(app, "live.mode.voice").waitForExistence(timeout: timeout), "with voice on")
        XCTAssertTrue(app.buttons["live.talk"].exists, "and the call controls")
        attachScreenshot(app, named: "live-lands-in-voice")

        // One tap: voice off, the same thread, typed.
        tapWhenEnabled(app.buttons["live.voice.disable"])
        XCTAssertTrue(element(app, "live.composer").waitForExistence(timeout: timeout), "Type instead turns voice off")
        XCTAssertTrue(element(app, "live.mode.text").exists)
        XCTAssertTrue(spoken.exists, "in the same conversation")
        attachScreenshot(app, named: "live-voice-off-same-conversation")

        // Two taps: New conversation and its confirmation.
        app.buttons["live.conversation.new"].tap()
        let confirm = app.buttons["Start new conversation"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout), "New conversation asks before ending this one")
        confirm.tap()
        XCTAssertTrue(waitForGone(spoken), "a fresh thread replaces the old one")
        XCTAssertTrue(element(app, "live.composer").waitForExistence(timeout: timeout), "typed, as the one it replaced was")
        attachScreenshot(app, named: "live-new-conversation")
    }

    func test_the_live_button_turns_voice_back_on_in_a_conversation_left_typed() throws {
        let app = launch()
        openLive(app)
        tapWhenEnabled(app.buttons["live.voice.disable"])
        XCTAssertTrue(element(app, "live.composer").waitForExistence(timeout: timeout))
        closeLive(app)

        openLive(app)
        XCTAssertTrue(labelled(app, "Is the flaky poller test still failing on main?").waitForExistence(timeout: timeout), "the same conversation")
        XCTAssertTrue(element(app, "live.mode.voice").waitForExistence(timeout: timeout), "with voice on again")
        XCTAssertTrue(app.buttons["live.voice.disable"].exists)
    }

    func test_the_live_button_starts_a_conversation_with_voice_on_when_none_is_open() throws {
        let app = launch()
        openLive(app)
        let spoken = labelled(app, "Is the flaky poller test still failing on main?")
        XCTAssertTrue(spoken.waitForExistence(timeout: timeout))
        app.buttons["live.conversation.menu"].tap()
        app.buttons["End conversation"].tap()
        XCTAssertTrue(waitForGone(app.buttons["live.voice.disable"]), "an ended conversation has no call controls")
        closeLive(app)

        openLive(app)
        XCTAssertTrue(element(app, "live.mode.voice").waitForExistence(timeout: timeout), "a new conversation, voice on")
        XCTAssertTrue(labelled(app, "Press Talk and say what you need.").exists, "with nothing said yet")
        XCTAssertFalse(spoken.exists, "not the ended one")
        attachScreenshot(app, named: "live-lands-in-new-voice-conversation")
    }

    func test_live_mode_is_entered_from_the_main_screen_typed_into_and_ended() throws {
        let app = launch()
        openLive(app)
        XCTAssertTrue(element(app, "live.mode.voice").waitForExistence(timeout: timeout))
        back(app)

        XCTAssertTrue(app.descendants(matching: .any)["live.mode"].waitForExistence(timeout: timeout), "Back leads to one Live Mode")
        XCTAssertFalse(labelled(app, "Live Voice").exists, "no separate Live Voice")
        XCTAssertTrue(app.descendants(matching: .any)["live.resume"].exists, "the open conversation can be resumed")
        attachScreenshot(app, named: "live-home")

        let start = app.descendants(matching: .any)["live.start"].firstMatch
        start.tap()
        let composer = app.descendants(matching: .any)["live.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: timeout), "a new conversation opens typed, with its composer")
        XCTAssertTrue(app.buttons["live.voice.enable"].exists, "voice is turned on from inside the conversation")
        composer.tap()
        let typed = "Please look into the flaky poller test"
        composer.typeText(typed)
        // The vertical TextField's binding can trail its text view, so a tap that lands quickly
        // sends a prefix of what was typed: on a loaded runner, "Please look into the flaky po".
        // Waiting for the text view to hold all of it narrows that, and the thread is checked
        // for the part the fixture answers to ("look into") rather than for every character.
        XCTAssertTrue(waitForValue(composer, typed), "the composer holds what was typed")
        app.buttons["live.send"].tap()

        XCTAssertTrue(labelled(app, "Please look into").waitForExistence(timeout: timeout), "what was typed is in the thread")
        XCTAssertTrue(labelled(app, "quick_router").waitForExistence(timeout: timeout), "the delegation shows as a tool line")
        XCTAssertTrue(labelled(app, "Started a session on that").waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "live-mode-thread")

        app.buttons["live.conversation.menu"].tap()
        app.buttons["End conversation"].tap()
        XCTAssertTrue(waitForGone(app.descendants(matching: .any)["live.composer"].firstMatch), "an ended conversation takes no more messages")
    }

    func test_a_thread_with_voice_on_shows_what_was_said_the_call_controls_and_type_instead() throws {
        let app = launch(["-ZimmerFixtureLiveConversation", "21"])
        XCTAssertTrue(labelled(app, "Is the flaky poller test still failing on main?").waitForExistence(timeout: timeout))
        XCTAssertTrue(labelled(app, "quick_router").exists)
        XCTAssertTrue(app.buttons["live.talk"].exists, "Talk starts the call")
        attachScreenshot(app, named: "live-voice-thread")

        app.buttons["live.voice.disable"].tap()
        let composer = app.descendants(matching: .any)["live.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: timeout), "Type instead turns the same thread back to typing")
        XCTAssertTrue(labelled(app, "Is the flaky poller test still failing on main?").exists, "the spoken turns stay in the thread")
        XCTAssertTrue(app.buttons["live.voice.enable"].exists)
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

    private func openLive(_ app: XCUIApplication) {
        let open = app.buttons["live.open"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout), "the waveform button is on the session list")
        open.tap()
    }

    /// From a conversation: Back to the Live list, then Done.
    private func closeLive(_ app: XCUIApplication) {
        back(app)
        let done = app.buttons["live.done"]
        XCTAssertTrue(done.waitForExistence(timeout: timeout))
        done.tap()
        XCTAssertTrue(waitForGone(done))
    }

    /// The conversation's Back button, to the Live list.
    private func back(_ app: XCUIApplication) {
        let bar = app.navigationBars["Live Mode"]
        let named = bar.buttons["Live"]
        let back = named.waitForExistence(timeout: 2) ? named : bar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: timeout))
        back.tap()
    }

    /// Waits for the button to exist and take a tap, then taps it.
    private func tapWhenEnabled(_ button: XCUIElement) {
        let enabled = expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: button)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed, "\(button) is enabled")
        button.tap()
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
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

    private func waitForValue(_ element: XCUIElement, _ text: String) -> Bool {
        let holds = expectation(for: NSPredicate(format: "value == %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [holds], timeout: timeout) == .completed
    }

    private func waitForGone(_ element: XCUIElement) -> Bool {
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
