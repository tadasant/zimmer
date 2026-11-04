import XCTest

/// The CarPlay drill: Zimmer opened in the iOS Simulator's CarPlay window and driven through
/// the car's app: it opens on one button; the gear on the call screen opens the voice settings,
/// which show what a voice call left behind, change it and reset it, and the call comes back; and
/// a call that cannot connect fails, retries and puts the call screen up and down again and
/// again, gives up and says so on the button, and a tap after that tries again. After every step Zimmer must still be running, and no call
/// screen may be left over a car with no call: those are the changes CarPlay turns into an
/// exception, and a crash, as it did in a car (#1410).
///
/// The CarPlay window is a second display that only the Simulator app's menu can switch on,
/// so `ios/bin/ui-test --carplay` opens it and sets `ZIMMER_UI_TEST_CARPLAY`. Without that
/// the class skips, so a smoke run that names this file is not red for want of a car. The
/// call fails because the fixture's Realtime secret points at `realtime.invalid`: the drill
/// needs no microphone, no network and no OpenAI key.
///
/// CarPlay's screens are drawn by the system's `CarPlayTemplateUIHost`, not by Zimmer, so the
/// queries go through that app; the home screen the icon is on is `CarPlayApp`.
@MainActor
final class CarPlayDrillUITests: XCTestCase {
    private let timeout: TimeInterval = 20
    private var zimmer: XCUIApplication!
    private let dashboard = XCUIApplication(bundleIdentifier: "com.apple.CarPlayApp")
    private let car = XCUIApplication(bundleIdentifier: "com.apple.CarPlayTemplateUIHost")

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["ZIMMER_UI_TEST_CARPLAY"] == "1" else {
            throw XCTSkip("needs the Simulator's CarPlay window: run it with ios/bin/ui-test --carplay")
        }
    }

    // MARK: - The drill

    /// The car app, in order, in one Zimmer process: CarPlay connects a scene to the first
    /// process and, in the Simulator, never to one XCUITest relaunches (its window stays blank),
    /// so the steps share one launch rather than one each.
    ///
    /// Mute and End are not pressed. XCUITest finds the voice control template's two action
    /// buttons ("microphone off", "hang up") but computes no hit point for them, and neither an
    /// element tap nor a coordinate tap reaches them, so the drill cannot drive them; the five
    /// states they switch between are `LiveCallScreenTests`', and the rest is driving.
    ///
    /// `-ZimmerFixtureVoiceTurnedUp` starts the Live settings where voice calls left them on the
    /// call that broke, and holds the first call on Connecting…, so the call screen stays up to
    /// be driven; every call after it fails as fast as ever.
    func test_open_on_one_button_then_the_gear_then_a_call_that_cannot_connect_retries_gives_up_and_tries_again() {
        XCTAssertGreaterThanOrEqual(XCUIScreen.screens.count, 2, "the CarPlay window is a second screen, and there is none")
        zimmer = XCUIApplication()
        zimmer.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureVoiceTurnedUp"]
        zimmer.launch()
        openInTheCar()

        // Open: one button, and nothing else.
        XCTAssertTrue(text("Talk to Zimmer").waitForExistence(timeout: timeout), "the one button is Talk to Zimmer")
        for gone in ["Needs you", "Running"] {
            XCTAssertFalse(car.buttons[gone].exists, "no \(gone) tab: the car is one button")
        }
        XCTAssertEqual(car.cells.count, 1, "one button on the screen; the car showed:\n\(car.debugDescription)")
        photograph("carplay-home")
        assertAlive("on the home screen")

        // The gear: on the call screen, one touch, in any state of the call.
        tapTile("Talk to Zimmer")
        XCTAssertTrue(text("Connecting…").waitForExistence(timeout: timeout), "the call screen goes up; the car showed:\n\(car.debugDescription)")
        photograph("carplay-call-screen-gear")
        record("the call screen", car.debugDescription)
        let clicked = clickTheGear()
        record("the gear", clicked ? "a click in the CarPlay window opened the panel" : "no click reached the gear: the fixture pressed it")
        print("carplay drill: the gear was \(clicked ? "pressed by a click in the CarPlay window" : "pressed by the fixture")")
        XCTAssertTrue(row("Back to the call").waitForExistence(timeout: timeout), "the gear opens the voice settings; the car showed:\n\(car.debugDescription)")
        assertNoCallScreen("under the voice settings: the microphone is closed with it")
        assertAlive("with the voice settings up")

        // What voice left behind, the reply cap first. Under Semantic the threshold would go
        // nowhere, so there is no row for it.
        XCTAssertTrue(row("Reply length cap").waitForExistence(timeout: timeout), "the settings load; the car showed:\n\(car.debugDescription)")
        XCTAssertTrue(anything(containing: "180").exists, "the cap a voice call set is the cap shown; the car showed:\n\(car.debugDescription)")
        XCTAssertFalse(row("Speech threshold").exists, "no control that does nothing under Semantic")
        photograph("carplay-voice-settings")

        // Silence: the threshold is real there, so it appears, with the value voice left.
        press("Turn detection", until: row("Back to settings"))
        photograph("carplay-voice-settings-choices")
        press("Silence", until: row("Speech threshold"))
        XCTAssertTrue(anything(containing: "0.92").exists, "the value voice left; the car showed:\n\(car.debugDescription)")
        photograph("carplay-voice-settings-silence")

        // Reset to defaults: no cap, back on Semantic, and the threshold's row gone with it.
        press("Reset to defaults", until: anything(containing: "No cap (default)"))
        XCTAssertFalse(row("Speech threshold").exists, "and it is back on Semantic")
        photograph("carplay-voice-settings-reset")
        assertAlive("after the reset")

        // Back to the call: the same conversation is called again, and in this fixture that call
        // cannot connect (its Realtime secret points at realtime.invalid). The call screen goes
        // up, the call fails, and the car retries after 2, 5 and 15 seconds, each retry putting
        // the call screen up and taking it down — the churn that crashed it.
        press("Back to the call", until: car.descendants(matching: .any).matching(NSPredicate(format: "label == 'Connecting…' OR label CONTAINS 'etry'")).firstMatch)
        XCTAssertTrue(waitFor(anyOf: ["Retrying…", "Live Mode unavailable, retrying…"], seconds: 30), "a failed call says it is retrying, on the button")
        photograph("carplay-retrying")
        XCTAssertTrue(waitFor(anyOf: ["Retry", "Live Mode unavailable. Tap to retry"], seconds: 90), "and once the retries are spent, that Live Mode is unavailable")
        assertNoCallScreen("once the car has given up")
        photograph("carplay-unavailable")
        assertAlive("after three retries")

        // A tap after giving up is a fresh set of retries.
        tapTile("Retry", or: "Live Mode unavailable. Tap to retry")
        XCTAssertTrue(waitFor(anyOf: ["Retrying…", "Live Mode unavailable, retrying…"], seconds: 30), "a tap tries again")
        assertAlive("at the end of the drill")
    }

    // MARK: - Getting there

    /// Zimmer's CarPlay scene, from the CarPlay home screen: home first, in case the car is on
    /// another app, then Zimmer's icon.
    private func openInTheCar() {
        if text("Talk to Zimmer").waitForExistence(timeout: 5) { return }
        let home = dashboard.descendants(matching: .any)["CARStatusBarHomeButton"]
        if home.exists {
            home.tap()
        }
        let icon = dashboard.descendants(matching: .any).matching(NSPredicate(format: "label == 'Zimmer'")).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: timeout), "Zimmer is on the CarPlay home screen; it showed:\n\(dashboard.debugDescription)")
        icon.tap()
        XCTAssertTrue(text("Talk to Zimmer").waitForExistence(timeout: timeout), "Zimmer's CarPlay scene connected; the car showed:\n\(car.debugDescription)")
    }

    /// Any element with these words: the button's text, or the call screen's title.
    private func text(_ label: String) -> XCUIElement {
        car.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A list row by its title: the cell has no label of its own, its title and detail do.
    private func row(_ words: String) -> XCUIElement {
        car.cells.containing(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    /// Press a list row, and wait for `shown`. A tap if XCUITest can reach it, a click from the
    /// Mac if it cannot.
    private func press(_ words: String, until shown: XCUIElement) {
        let target = row(words)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "no \(words) row; the car showed:\n\(car.debugDescription)")
        target.tap()
        if shown.waitForExistence(timeout: 4) { return }
        click(target)
        XCTAssertTrue(shown.waitForExistence(timeout: timeout), "\(words) did nothing; the car showed:\n\(car.debugDescription)")
    }

    private func anything(containing words: String) -> XCUIElement {
        car.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// The gear is a bar button with no words, so it goes by its symbol's name. XCUITest finds it
    /// and computes no hit point for it, as for Mute and End, so `ios/bin/ui-test` clicks it from
    /// the Mac (see `carplay-click` there). True when that opened the panel. The fixture presses
    /// the gear's action a few seconds later either way, so the panel is driven whichever it was.
    private func clickTheGear() -> Bool {
        let gear = car.buttons["gearshape.fill"]
        XCTAssertTrue(gear.waitForExistence(timeout: timeout), "no gear on the call screen; the car showed:\n\(car.debugDescription)")
        click(gear)
        return row("Back to the call").waitForExistence(timeout: 6)
    }

    /// A click from the Mac at `element`'s place in the CarPlay window (`carplay-click` in
    /// `ios/bin/ui-test`).
    private func click(_ element: XCUIElement) {
        guard element.exists, let artifacts = ProcessInfo.processInfo.environment["ZIMMER_UI_TEST_ARTIFACTS"] else { return }
        let window = car.windows.firstMatch.frame
        let spot = "\(element.frame.midX / window.width) \(element.frame.midY / window.height)\n"
        try? spot.write(toFile: artifacts + "/carplay-click", atomically: true, encoding: .utf8)
    }

    /// What XCUITest could see, kept with the run.
    private func record(_ name: String, _ tree: String) {
        let attachment = XCTAttachment(string: tree)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapTile(_ label: String, or other: String? = nil) {
        // A grid tile is a button named for its symbol with the tile's words as a text inside.
        let tile = car.buttons.containing(NSPredicate(format: "label == %@", label)).firstMatch
        if tile.waitForExistence(timeout: timeout) {
            tile.tap()
            return
        }
        if let other {
            let alternative = car.buttons.containing(NSPredicate(format: "label == %@", other)).firstMatch
            if alternative.waitForExistence(timeout: 2) {
                alternative.tap()
                return
            }
        }
        XCTFail("no \(label) tile; the car showed:\n\(car.debugDescription)")
    }

    /// Polls rather than one `waitForExistence`, checking Zimmer is alive each second, so a
    /// crash fails the drill when it happens rather than when the wait runs out.
    private func waitFor(anyOf labels: [String], seconds: Int) -> Bool {
        for _ in 0..<seconds {
            if labels.contains(where: { text($0).exists }) { return true }
            assertAlive("while waiting for \(labels.joined(separator: " or "))")
            Thread.sleep(forTimeInterval: 1)
        }
        return labels.contains(where: { text($0).exists })
    }

    /// The call screen's title is one of its five states. With no call it must be gone: a call
    /// screen left up over a car that gave up is the bug this drill first caught (CarPlay hands
    /// back a stand-in for the template it presented, so a dismissal that compared by identity
    /// never happened).
    private func assertNoCallScreen(_ when: String) {
        let titles = ["Connecting…", "Listening", "Speaking", "Working on it…", "Muted"]
        let title = car.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", titles)).firstMatch
        let gone = NSPredicate(format: "exists == false")
        let wait = XCTNSPredicateExpectation(predicate: gone, object: title)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 10), .completed,
                       "the call screen is still up \(when); the car showed:\n\(car.debugDescription)")
    }

    private func assertAlive(_ when: String) {
        XCTAssertTrue(zimmer.state == .runningForeground || zimmer.state == .runningBackground,
                      "Zimmer is not running \(when): it crashed (state \(zimmer.state.rawValue))")
    }

    /// The CarPlay window, kept with the run.
    private func photograph(_ name: String) {
        guard XCUIScreen.screens.count > 1 else { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.screens[1].screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
