import XCTest

/// The CarPlay drill: Zimmer opened in the iOS Simulator's CarPlay window and driven through
/// the car's app: it opens on one button, and a call that cannot connect fails, retries and puts
/// the call screen up and down again and again, gives up and says so on the button, and a tap
/// after that tries again. After every step Zimmer must still be running, and no call
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
    func test_open_on_one_button_then_a_call_that_cannot_connect_retries_gives_up_and_tries_again() {
        XCTAssertGreaterThanOrEqual(XCUIScreen.screens.count, 2, "the CarPlay window is a second screen, and there is none")
        zimmer = XCUIApplication()
        zimmer.launchArguments = ["-ZimmerFixture"]
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

        // A call that cannot connect (the fixture's Realtime secret points at realtime.invalid):
        // the call screen goes up, the call fails, and the car retries after 2, 5 and 15 seconds,
        // each retry putting the call screen up and taking it down — the churn that crashed it.
        tapTile("Talk to Zimmer")
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
