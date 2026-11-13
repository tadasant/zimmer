import XCTest

/// The CarPlay drill: Zimmer opened in the iOS Simulator's CarPlay window and driven through
/// the car's app: it opens on Continue and New; Continue goes to the call screen, which shows the
/// gear; the car is unplugged from under that call, by the Simulator's own menu, the phone lands on
/// it, and plugged back in the call is on the car again; the gear's closure
/// (run by the fixture: no tap of XCUITest's reaches the gear itself) opens the voice settings,
/// which show what a voice call left behind, change it and reset it, and the call comes back; and
/// a call that cannot connect fails, retries and puts the call screen up and down again and
/// again, gives up and says so on a tile beside New; New is one tap to a call of its own; and a
/// conversation ended on the phone leaves only New. After every step Zimmer must still be running, and no call
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
    /// When the fixture runs the gear's closure after the reconnected call screen goes up:
    /// `CarPlayLive.drillPressesTheGear`'s 25 seconds.
    private static let fixtureGearDelay: TimeInterval = 25
    /// How long CarPlay's host can take to show what the app sent it: a stall of 30 seconds or
    /// so, in which it answers neither the app nor XCUITest, on top of the time to draw. See
    /// limitations.md, "CarPlay's host can stop answering in the drill".
    private static let hostStall: TimeInterval = 45
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
    /// states they switch between are `LiveCallScreenTests`', and the rest is driving. Send now,
    /// in Mute's place on Hearing you, is the same: the fixture shows its state and runs its
    /// closure off the main thread.
    ///
    /// `-ZimmerFixtureVoiceTurnedUp` starts the Live settings where voice calls left them on the
    /// call that broke, and holds the first call on Connecting…, so the call screen stays up to
    /// be driven; every call after it fails as fast as ever.
    ///
    /// Nothing but a call ending brings the tiles back to rest, and no call here connects or can
    /// be ended, so the order is what reaches each state: the drill has one tap of Continue, at
    /// rest, and the nothing-to-continue state comes last, by the only route left: a Retry that
    /// finds the conversation gone.
    func test_open_on_continue_and_new_then_the_gear_then_retries_then_new_then_nothing_to_continue() {
        XCTAssertGreaterThanOrEqual(XCUIScreen.screens.count, 2, "the CarPlay window is a second screen, and there is none")
        zimmer = XCUIApplication()
        zimmer.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureVoiceTurnedUp"]
        zimmer.launch()
        openInTheCar()

        // Open: the two choices, and nothing else.
        XCTAssertTrue(waitFor(anyOf: Self.continueTitles, seconds: Int(timeout)), "Continue is offered: the fixture has a conversation open")
        XCTAssertTrue(waitFor(anyOf: Self.newTitles, seconds: Int(timeout)), "and New beside it")
        for gone in ["Needs you", "Running"] {
            XCTAssertFalse(car.buttons[gone].exists, "no \(gone) tab: the car is its two choices")
        }
        XCTAssertEqual(car.cells.count, 2, "two tiles on the screen; the car showed:\n\(car.debugDescription)")
        photograph("carplay-home")
        record("the home", car.debugDescription)
        assertAlive("on the home screen")

        // Continue: one tap to the call screen, where the gear is, on a call held on Connecting….
        tapTile(Self.continueTitles[0], or: Self.continueTitles[1])
        // The gear says the call screen is up, and the words cannot: the tile says Connecting…
        // while the tap finds its conversation, and on a stalled run that outlasts one look.
        // The screen also comes up wearing CarPlay's own Cancel, so the gear takes a wait of its
        // own. The photo and the tree come before the assertion, to be kept if it fails.
        let gearIsUp = car.buttons["gearshape.fill"].waitForExistence(timeout: timeout)
        photograph("carplay-call-screen-gear")
        record("the call screen", car.debugDescription)
        XCTAssertTrue(gearIsUp, "no gear on the call screen; the car showed:\n\(car.debugDescription)")
        XCTAssertTrue(text("Connecting…").waitForExistence(timeout: timeout), "the call is held on Connecting…; the car showed:\n\(car.debugDescription)")

        // The car goes away with the call up, by the Simulator's own menu: the scene really
        // disconnects, and the phone goes to the call.
        plug("Disabled")
        let landed = zimmer.descendants(matching: .any)["live.call.state"].firstMatch.waitForExistence(timeout: timeout)
        photographThePhone("carplay-phone-after-the-car-left")
        record("the phone after the car left", zimmer.debugDescription)
        XCTAssertTrue(landed, "the phone goes to the call; it showed:\n\(zimmer.debugDescription)")
        assertAlive("with the car gone and the call on the phone")

        // The car comes back: the call goes up on it again, and the phone stays as it is.
        plug("CarPlay")
        openInTheCar(callIsUp: true)
        XCTAssertTrue(car.buttons["gearshape.fill"].waitForExistence(timeout: timeout), "the call goes back to the car; the car showed:\n\(car.debugDescription)")
        // The fixture presses the gear on its own clock, counted from when the app hears this
        // call screen went up, about when the drill sees the gear; `hostStall` covers the
        // difference.
        let gearPressed = Date().addingTimeInterval(Self.fixtureGearDelay)
        photograph("carplay-call-screen-after-the-car-came-back")
        assertAlive("with the car back")

        // Send now, in its state: the fixture shows Hearing you on this call, which hears nobody,
        // a few seconds after it goes up, and runs Send now's closure off the main thread a few
        // seconds after that. With no speech it finds nothing to send, so the screen stays as it
        // is and Zimmer stays up. XCUITest cannot press it, as it cannot press Mute or End.
        let hearing = text("Hearing you").waitForExistence(timeout: timeout)
        photograph("carplay-call-screen-send-now")
        record("the call screen with Send now", car.debugDescription)
        // What CarPlay calls the button, which is what VoiceOver reads: the symbol's own words.
        record("the call screen's button labels", car.buttons.allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
        XCTAssertTrue(hearing, "Send now's state goes up; the car showed:\n\(car.debugDescription)")
        Thread.sleep(forTimeInterval: 7)
        assertAlive("after Send now's closure ran off the main thread")
        XCTAssertTrue(text("Hearing you").exists, "a Send now with nothing to send leaves the screen as it is; the car showed:\n\(car.debugDescription)")

        // XCUITest finds the gear and computes no hit point for it, as for Mute and End, and a
        // click from the Mac at its place does not reach it either. So the fixture runs the
        // gear's own closure, off the main thread, 25 seconds after the call screen goes up. The
        // wait runs to `hostStall` past that press.
        let panelWait = max(0, gearPressed.timeIntervalSinceNow) + Self.hostStall
        XCTAssertTrue(row("Back to the call").waitForExistence(timeout: panelWait), "the gear opens the voice settings; the car showed:\n\(car.debugDescription)")
        assertNoCallScreen("under the voice settings: the microphone is closed with it", panelUp: true)
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
        XCTAssertFalse(row("Reply length cap").exists, "the panel has left the stack")
        XCTAssertTrue(waitFor(anyOf: Self.retryingTitles, seconds: 30), "a failed call says it is retrying, on the tile")
        photograph("carplay-retrying")
        XCTAssertTrue(waitFor(anyOf: Self.retryTitles, seconds: 90), "and once the retries are spent, that Live Mode is unavailable")
        assertNoCallScreen("once the car has given up")
        XCTAssertTrue(waitFor(anyOf: Self.newTitles, seconds: Int(timeout)), "New stays beside Retry: the way out of a conversation that will not connect")
        XCTAssertEqual(car.cells.count, 2, "Retry and New; the car showed:\n\(car.debugDescription)")
        photograph("carplay-unavailable")
        assertAlive("after three retries")

        // New: one tap to a call on a conversation of its own, which in this fixture cannot
        // connect either, so it retries that conversation and gives up the same way.
        tapTile(Self.newTitles[0], or: Self.newTitles[1])
        XCTAssertTrue(waitFor(anyOf: Self.retryingTitles, seconds: 30), "New tries a call")
        XCTAssertTrue(waitFor(anyOf: Self.retryTitles, seconds: 90), "and gives up on its own conversation")
        assertNoCallScreen("once New has given up")
        assertAlive("after New")

        // Nothing to continue: the conversation ends on the phone, behind the car's tiles, and
        // Retry finds nothing open. The car starts nothing in its place: one tile, New.
        endTheConversationOnThePhone()
        tapTile(Self.retryTitles[1], or: Self.retryTitles[0])
        waitForOneTile()
        XCTAssertTrue(waitFor(anyOf: Self.newTitles, seconds: Int(timeout)), "with nothing open, New is what is left")
        XCTAssertFalse(Self.continueTitles.contains { text($0).exists }, "nothing to continue; the car showed:\n\(car.debugDescription)")
        assertNoCallScreen("with nothing to continue")
        photograph("carplay-home-nothing-to-continue")
        assertAlive("with nothing to continue")

        // And New from there is one tap too. With the microphone refused it gives up at once
        // rather than retrying, because no retry brings a microphone back; either way it tried.
        tapTile(Self.newTitles[0], or: Self.newTitles[1])
        XCTAssertTrue(waitFor(anyOf: Self.retryingTitles + Self.retryTitles, seconds: 30), "New from the one tile tries a call")
        assertAlive("at the end of the drill")
    }

    // MARK: - Getting there

    /// Zimmer's CarPlay scene, from the CarPlay home screen: home first, in case the car is on
    /// another app, then Zimmer's icon. `callIsUp`: the scene opens on the call, not the tiles.
    ///
    /// Nothing asks CarPlay's host (`car`) before the icon is tapped: only the dashboard. Just after
    /// the car is plugged back in, the host can stop answering XCUITest, and a query there fails
    /// the drill with `Failed to get matching snapshots` once its three 30-second tries run out.
    /// A look there first would find nothing anyway: the scene comes up from the icon, at launch
    /// and after the plug.
    private func openInTheCar(callIsUp: Bool = false) {
        let home = dashboard.descendants(matching: .any)["CARStatusBarHomeButton"]
        if home.waitForExistence(timeout: 5) {
            home.tap()
        }
        let icon = dashboard.descendants(matching: .any).matching(NSPredicate(format: "label == 'Zimmer'")).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: timeout), "Zimmer is on the CarPlay home screen; it showed:\n\(dashboard.debugDescription)")
        icon.tap()
        guard !callIsUp else { return }
        XCTAssertTrue(waitFor(anyOf: Self.newTitles, seconds: Int(timeout)), "Zimmer's CarPlay scene connected; the car showed:\n\(car.debugDescription)")
    }

    /// Clicks an item of the Simulator's External Displays menu, through `ios/bin/ui-test`: only
    /// the Mac can reach it. It removes the file once it has clicked.
    private func plug(_ item: String) {
        let directory = ProcessInfo.processInfo.environment["ZIMMER_UI_TEST_ARTIFACTS"] ?? ""
        let file = URL(fileURLWithPath: directory).appendingPathComponent("carplay-plug")
        XCTAssertNoThrow(try Data(item.utf8).write(to: file))
        for _ in 0..<60 where FileManager.default.fileExists(atPath: file.path) {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "ios/bin/ui-test did not click \(item)")
    }

    /// End the open conversation from the phone's own Live screen, in this same process. The
    /// fixture lands there with voice on and starts no call.
    ///
    /// Each car call has asked for the microphone, so the system's prompt can be up over the
    /// phone. Don't Allow keeps the audio engine out of the rest of the drill, and it is the
    /// first button.
    private func endTheConversationOnThePhone() {
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if prompt.waitForExistence(timeout: 3) {
            record("the microphone prompt", prompt.debugDescription)
            prompt.buttons.element(boundBy: 0).tap()
        }
        // The phone is still on the thread it landed on when the car left, and that is the
        // conversation New ended: back out, and in again to the one that is open.
        let thread = zimmer.navigationBars["Live Mode"]
        if thread.waitForExistence(timeout: 3) {
            thread.buttons.element(boundBy: 0).tap()
            let done = zimmer.buttons["live.done"]
            XCTAssertTrue(done.waitForExistence(timeout: timeout), "Back leads to the Live list; the phone showed:\n\(zimmer.debugDescription)")
            done.tap()
        }
        let open = zimmer.buttons["live.open"]
        XCTAssertTrue(open.waitForExistence(timeout: timeout), "the waveform button is on the phone's session list")
        open.tap()
        let menu = zimmer.buttons["live.conversation.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout), "the waveform button lands in the open conversation")
        menu.tap()
        let end = zimmer.buttons["End conversation"]
        XCTAssertTrue(end.waitForExistence(timeout: timeout), "the menu offers End conversation")
        end.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menu)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "the conversation ended on the phone")
    }

    /// The tile's words, longest first: CarPlay chooses among them by the width it has.
    private static let continueTitles = ["Continue conversation", "Continue"]
    private static let newTitles = ["New conversation", "New"]
    private static let retryingTitles = ["Live Mode unavailable, retrying…", "Retrying…"]
    private static let retryTitles = ["Live Mode unavailable. Tap to retry", "Retry"]

    /// Any element with these words: the tile's text, or the call screen's title.
    private func text(_ label: String) -> XCUIElement {
        car.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A list row by its title: the cell has no label of its own, its title and detail do. The
    /// list is a table; the grid's tile is a cell too, in a collection view, and during a call it
    /// says Back to the call.
    private func row(_ words: String) -> XCUIElement {
        car.tables.cells.containing(NSPredicate(format: "label BEGINSWITH %@", words)).firstMatch
    }

    /// Tap a list row, and wait for `shown`.
    private func press(_ words: String, until shown: XCUIElement) {
        let target = row(words)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "no \(words) row; the car showed:\n\(car.debugDescription)")
        target.tap()
        XCTAssertTrue(shown.waitForExistence(timeout: timeout), "\(words) did nothing; the car showed:\n\(car.debugDescription)")
    }

    private func anything(containing words: String) -> XCUIElement {
        car.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
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

    /// The home comes down to a single tile, checking Zimmer is alive each second.
    private func waitForOneTile() {
        for _ in 0..<Int(timeout) {
            if car.cells.count == 1 { return }
            assertAlive("while waiting for one tile")
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("still \(car.cells.count) tiles; the car showed:\n\(car.debugDescription)")
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
    ///
    /// With the voice settings up, *Listening* is one of their rows, so it says nothing there.
    private func assertNoCallScreen(_ when: String, panelUp: Bool = false) {
        var titles = ["Connecting…", "Hearing you", "Replying", "Muted"]
        if !panelUp { titles.append("Listening") }
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

    /// The phone's own screen, kept with the run.
    private func photographThePhone(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.screens[0].screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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
