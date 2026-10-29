import XCTest

/// The CarPlay drill: Zimmer opened in the iOS Simulator's CarPlay window and driven through
/// the flows that crashed it in a car (#1410). Talk to Zimmer with a call that cannot
/// connect, so it fails, retries and puts the call screen up and down again and again, then
/// gives up and says so on the tile. A tap after that is a fresh set of retries. Hang-up
/// happens mid-connect, and a Needs you row opens the same call. After every step Zimmer
/// must still be running: those are the changes CarPlay turns into an exception, and a crash.
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

    /// Zimmer launched on the fixture and opened in the car: the first line of every test.
    private func start() {
        XCTAssertGreaterThanOrEqual(XCUIScreen.screens.count, 2, "the CarPlay window is a second screen, and there is none")
        zimmer = XCUIApplication()
        zimmer.launchArguments = ["-ZimmerFixture"]
        zimmer.launch()
        openInTheCar()
    }

    // MARK: - The drill

    func test_the_car_opens_on_talk_and_the_two_counts() {
        start()
        XCTAssertTrue(text("Talk to Zimmer").waitForExistence(timeout: timeout), "the first tile is Talk to Zimmer")
        XCTAssertTrue(text("Needs you · 4").exists, "the fixture has four sessions that need you")
        XCTAssertTrue(text("Running · 2").exists, "and two at work")
        for tab in ["Zimmer", "Needs you", "Running"] {
            XCTAssertTrue(car.buttons[tab].exists, "the \(tab) tab")
        }
        photograph("carplay-home")
        assertAlive("on the home tab")
    }

    func test_a_call_that_cannot_connect_retries_quietly_gives_up_on_the_tile_and_never_crashes() {
        start()
        tapTile("Talk to Zimmer")
        // The fixture's call fails at once and the car retries after 2, 5 and 15 seconds.
        // Each retry puts the call screen up and takes it down: the churn that crashed it.
        XCTAssertTrue(waitFor(anyOf: ["Retrying…", "Live Mode unavailable, retrying…"], seconds: 30), "a failed call says it is retrying, on the tile")
        photograph("carplay-retrying")
        XCTAssertTrue(waitFor(anyOf: ["Retry", "Live Mode unavailable. Tap to retry"], seconds: 90), "and once the retries are spent, that Live Mode is unavailable")
        assertNoCallScreen("once the car has given up")
        photograph("carplay-unavailable")
        assertAlive("after three retries")

        // A tap after giving up is a fresh set of retries.
        tapTile("Retry", or: "Live Mode unavailable. Tap to retry")
        XCTAssertTrue(waitFor(anyOf: ["Retrying…", "Live Mode unavailable, retrying…"], seconds: 30), "a tap tries again")
        assertAlive("after trying again")
    }

    func test_hanging_up_while_it_connects_leaves_the_car_on_the_board() {
        start()
        tapTile("Talk to Zimmer")
        let hangUp = car.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'hang' OR label CONTAINS[c] 'phone.down' OR label CONTAINS[c] 'end'")).firstMatch
        guard hangUp.waitForExistence(timeout: 30) else {
            return XCTFail("no Hang up button on the call screen; the car showed:\n\(car.debugDescription)")
        }
        photograph("carplay-call")
        hangUp.tap()
        XCTAssertTrue(waitFor(anyOf: ["Talk to Zimmer"], seconds: 20), "hanging up goes back to Talk to Zimmer, with no retry")
        assertNoCallScreen("after hanging up")
        assertAlive("after hanging up")
    }

    func test_a_needs_you_row_opens_the_one_call() {
        start()
        car.buttons["Needs you"].tap()
        let row = car.cells.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "the Needs you list has the fixture's sessions")
        photograph("carplay-needs-you")
        row.tap()
        // The same call as Talk to Zimmer: the call screen, or its failure on the home tile.
        let call = car.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'hang' OR label CONTAINS[c] 'phone.down' OR label CONTAINS[c] 'end'")).firstMatch
        let reached = call.waitForExistence(timeout: 30) || waitFor(anyOf: ["Retrying…", "Live Mode unavailable, retrying…"], seconds: 5)
        XCTAssertTrue(reached, "a row starts the Live Mode call; the car showed:\n\(car.debugDescription)")
        assertAlive("after a row started the call")
    }

    // MARK: - Getting there

    /// Zimmer's CarPlay scene, from the CarPlay home screen. A relaunched Zimmer leaves the car
    /// on an empty app screen, its scene gone with the old process, so the car's home button
    /// goes back to the icons first.
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

    private func text(_ label: String) -> XCUIElement {
        car.staticTexts[label]
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

    /// The call screen's title begins with the call's state ("Connecting… · 4 need you"). With
    /// no call it must be gone: a call screen left up over a car that gave up is the bug this
    /// drill first caught (CarPlay hands back a stand-in for the template it presented, so a
    /// dismissal that compared by identity never happened).
    private func assertNoCallScreen(_ when: String) {
        let title = car.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Connecting' OR label BEGINSWITH 'Listening' OR label BEGINSWITH 'Speaking' OR label BEGINSWITH 'Thinking'")).firstMatch
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
