import XCTest

/// The Inference page under More, against the `-ZimmerFixture` in-memory Zimmer: the roster
/// and its states, the verbs with their confirmations, the login sheet, the policy forms'
/// in-place refusals, and a relay-only grant's 403. Every assertion is on state that stays
/// on screen, never on a toast.
@MainActor
final class InferenceUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_roster_shows_the_three_accounts_with_their_states_and_the_current_marker() throws {
        let app = launch()
        XCTAssertTrue(element(app, "inference.account.11").waitForExistence(timeout: timeout))
        XCTAssertTrue(element(app, "inference.account.11.current").exists, "ops is the current account")
        XCTAssertEqual(element(app, "inference.account.11.status").label, "Active")
        XCTAssertFalse(element(app, "inference.account.12.current").exists)
        XCTAssertTrue(element(app, "inference.account.11.window5h").label.contains("42.0%"))
        XCTAssertTrue(element(app, "inference.tab.claude_code").isSelected)
        attachScreenshot(app, named: "inference-roster")
        // A List realises its rows as they scroll in; the lower cards are reached, not assumed.
        let exceeded = element(app, "inference.account.12.status")
        reveal(app, exceeded)
        XCTAssertEqual(exceeded.label, "Quota Exceeded")
        let probe = element(app, "inference.account.13.probeError")
        reveal(app, probe)
        XCTAssertTrue(probe.exists, "the failed probe is on the card")
    }

    func test_make_current_after_confirming_moves_the_marker_and_it_persists_on_reopen() throws {
        let app = launch()
        XCTAssertTrue(element(app, "inference.account.11").waitForExistence(timeout: timeout))
        let activate = app.buttons["inference.account.12.activate"]
        reveal(app, activate)
        activate.tap()
        let confirm = app.sheets.buttons["Switch"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout), "the web page's confirmation, in its words")
        confirm.tap()
        XCTAssertTrue(element(app, "inference.account.12.current").waitForExistence(timeout: timeout), "the marker moved")
        XCTAssertTrue(waitForDisappearance(element(app, "inference.account.11.current")))

        app.navigationBars.buttons["More"].tap()
        element(app, "more.inference").tap()
        XCTAssertTrue(element(app, "inference.account.11").waitForExistence(timeout: timeout))
        XCTAssertFalse(element(app, "inference.account.11.current").exists)
        let moved = element(app, "inference.account.12.current")
        reveal(app, moved)
        XCTAssertTrue(moved.exists, "the switch persisted")
    }

    func test_refresh_updates_the_window_line() throws {
        let app = launch()
        let window = element(app, "inference.account.11.window5h")
        XCTAssertTrue(window.waitForExistence(timeout: timeout))
        XCTAssertTrue(window.label.contains("42.0%"))
        let refresh = app.buttons["inference.account.11.refresh"]
        reveal(app, refresh)
        refresh.tap()
        XCTAssertTrue(waitForLabelContaining(window, "45.0%"), "the fresh reading is on the card")
    }

    func test_add_account_walks_the_login_sheet_to_the_device_code_and_copy_then_done() throws {
        let app = launch(["codex"])
        XCTAssertTrue(element(app, "inference.account.14").waitForExistence(timeout: timeout))
        let add = app.buttons["inference.add"]
        reveal(app, add)
        add.tap()
        let email = app.textFields["inference.add.email"]
        XCTAssertTrue(email.waitForExistence(timeout: timeout))
        email.tap()
        email.typeText("new@tadasant.com")
        app.buttons["inference.add.submit"].tap()

        // The login sheet: the fake's CLI prints the link and the one-time code on the first poll.
        let status = app.staticTexts["inference.login.status"]
        XCTAssertTrue(status.waitForExistence(timeout: timeout), "the account was added and its login started")
        let code = app.staticTexts["inference.login.code"]
        XCTAssertTrue(code.waitForExistence(timeout: timeout), "the device code arrived on a poll")
        XCTAssertEqual(code.label, "WXYZ-7K2Q")
        XCTAssertTrue(app.buttons["inference.login.url"].exists, "the verification link is offered")
        // Copy first: the code is up for ten seconds of the fake's polls, and a screenshot on a
        // loaded simulator can take a few of them.
        app.buttons["inference.login.copy"].tap()
        XCTAssertEqual(app.buttons["inference.login.copy"].label, "Copied")
        XCTAssertTrue(app.buttons["inference.login.cancel"].exists)
        attachScreenshot(app, named: "inference-login-code")

        XCTAssertTrue(waitForLabelContaining(status, "Signed in", timeout: 40), "the fake's later polls finish the login")
        XCTAssertFalse(app.buttons["inference.login.cancel"].exists, "a finished login has nothing to cancel")
        app.buttons["inference.login.done"].tap()
        XCTAssertTrue(element(app, "inference.account.14").waitForExistence(timeout: timeout))
        let status20 = element(app, "inference.account.20.status")
        reveal(app, status20)
        XCTAssertEqual(status20.label, "Active", "the added account is on the roster with the credentials its login captured")
    }

    func test_a_spot_policy_field_out_of_range_shows_the_refusal_in_place_and_the_stored_value_stays() throws {
        let app = launch()
        XCTAssertTrue(element(app, "inference.account.11").waitForExistence(timeout: timeout))
        let field = app.textFields["inference.spot.max_concurrent_sessions"]
        reveal(app, field)
        XCTAssertEqual(field.value as? String, "4")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "250")
        // The number pad has no Done: a scroll puts the keyboard away (the page dismisses it on
        // a drag), so the tap on Save lands on Save and not on the keys. A held drag above the
        // keys, not a flung swipe, so Save is not carried past the bar and out of the List.
        drag(app, towardTop: false, from: 0.5)
        XCTAssertTrue(waitForDisappearance(app.keyboards.firstMatch), "the keyboard is gone")
        let save = app.buttons["inference.spot.save"]
        reveal(app, save)
        save.tap()
        let refusal = app.staticTexts["inference.spot.error"]
        XCTAssertTrue(refusal.waitForExistence(timeout: timeout))
        XCTAssertTrue(refusal.label.contains("Spot max concurrent sessions must be less than or equal to 100"), refusal.label)
        attachScreenshot(app, named: "inference-spot-refused")

        app.navigationBars.buttons["More"].tap()
        element(app, "more.inference").tap()
        XCTAssertTrue(element(app, "inference.account.11").waitForExistence(timeout: timeout))
        reveal(app, field)
        XCTAssertEqual(field.value as? String, "4", "nothing persisted")
    }

    func test_a_relay_only_grant_sees_the_403_in_place() throws {
        let app = launch(["-ZimmerFixtureRelayOnly"])
        XCTAssertTrue(element(app, "inference.account.11").waitForExistence(timeout: timeout))
        let activate = app.buttons["inference.account.12.activate"]
        reveal(app, activate)
        activate.tap()
        let confirm = app.sheets.buttons["Switch"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()
        let refusal = app.staticTexts["inference.error"]
        XCTAssertTrue(refusal.waitForExistence(timeout: timeout))
        XCTAssertTrue(refusal.label.contains("may not act as you"), refusal.label)
        XCTAssertFalse(element(app, "inference.account.12.current").exists, "nothing changed")
        let current = element(app, "inference.account.11.current")
        reveal(app, current)
        XCTAssertTrue(current.exists)
    }

    // MARK: - Helpers

    /// More → Inference, on the Claude Code tab unless `extra` names a runtime.
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureInference"] + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// isHittable says yes while a control is still under the navigation bar, where a tap lands
    /// on the bar, or under the tab bar: scroll until it sits between the two, a quarter-screen
    /// drag at a time, held at the end so there is no fling to carry it across the band. A List
    /// keeps only the rows on screen, so an element not in the hierarchy is looked for further
    /// down the page, or back up it if it was last seen above the bar. The drag starts from one
    /// of three heights in turn, since a press that lands on a full-width button is swallowed
    /// by it and moves nothing.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        let bar = app.navigationBars.firstMatch
        func top() -> CGFloat { bar.exists ? bar.frame.maxY : 0 }
        func laidOut() -> CGRect? {
            element.exists && !element.frame.isEmpty ? element.frame : nil
        }
        var lastSeenAbove = false
        /// Whether what is wanted is above the band (true) or below it (false); nil once it is in
        /// the band. Reading it also records where a laid-out element was last seen.
        func revealAbove() -> Bool? {
            guard let frame = laidOut() else { return lastSeenAbove }
            lastSeenAbove = frame.minY < top()
            if lastSeenAbove { return true }
            if frame.maxY > app.frame.maxY - 110 { return false }
            return nil
        }
        let starts: [CGFloat] = [0.7, 0.6, 0.5]
        for attempt in 0..<30 {
            guard let above = revealAbove() else { break }
            drag(app, towardTop: above, from: starts[attempt % starts.count])
        }
        let placed = revealAbove() == nil
        if !placed {
            print("reveal gave up: element \(laidOut().map { "\($0)" } ?? "not laid out"), bar \(bar.exists ? "\(bar.frame)" : "absent")")
        }
        XCTAssertTrue(placed, "\(element) is scrolled into view")
    }

    /// A quarter-screen drag starting at height `start`, held at the end so there is no fling.
    /// The finger moves down to bring what is above into view, up for what is below.
    private func drag(_ app: XCUIApplication, towardTop: Bool, from start: CGFloat) {
        let (from, to): (CGFloat, CGFloat) = towardTop ? (start - 0.25, start) : (start, start - 0.25)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                   withVelocity: .default, thenHoldForDuration: 0.3)
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String, timeout: TimeInterval? = nil) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout ?? self.timeout) == .completed
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
