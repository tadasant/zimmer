import XCTest

/// The Sign-in card, Deployment Information and the API keys & connections screen, against
/// the `-ZimmerFixture` in-memory Zimmer. Every assertion is on state that stays — a row's
/// badges, which button a row offers, what is still there after the screen is opened again —
/// never on a toast.
@MainActor
final class AccountUITests: XCTestCase {
    private let timeout: TimeInterval = 20
    /// `Api::BaseController#require_a_person_on_the_app`'s message on the app's own token.
    private let relayOnlyRefusal = "This sign-in may not act as you; sign in again and allow acting as you"

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_sign_in_card_says_who_and_how_and_the_deployment_says_its_commit() throws {
        let app = launch()
        openSettings(app)

        XCTAssertEqual(app.staticTexts["settings.signin.email"].label, "Signed in as tadas@example.com")
        XCTAssertTrue(app.staticTexts["settings.signin.privilege"].label.hasPrefix("This connection acts on your behalf"))
        XCTAssertTrue(app.staticTexts["settings.signin.totp"].label.hasPrefix("Authenticator set up"))
        XCTAssertEqual(app.staticTexts["settings.signin.recovery"].label, "8 recovery codes left")
        let everywhere = app.buttons["settings.signin.everywhere"]
        reveal(app, everywhere)
        XCTAssertTrue(everywhere.isEnabled, "offered once the server has said who this is")

        // Deployment Information is the last section, below the page's own: a long way down.
        let sha = app.staticTexts["settings.deployment.sha"]
        reveal(app, sha)
        XCTAssertEqual(sha.label, "b7d4e1c", "the short SHA; the whole one is a long-press away")
        let branch = app.staticTexts["settings.deployment.branch"]
        reveal(app, branch)
        XCTAssertEqual(branch.label, "main")
        let environment = app.staticTexts["settings.deployment.environment"]
        reveal(app, environment)
        XCTAssertEqual(environment.label, "production")
    }

    func test_the_connections_screen_marks_this_phone_and_a_revoke_marks_the_other_revoked() throws {
        let app = launch()
        openAccount(app)

        let phone = app.descendants(matching: .any)["account.grant.7"]
        XCTAssertTrue(phone.label.contains("This phone"))
        XCTAssertTrue(phone.label.contains("Acts on your behalf"))
        let other = app.descendants(matching: .any)["account.grant.4"]
        reveal(app, other)
        XCTAssertFalse(other.label.contains("This phone"))
        XCTAssertTrue(other.label.contains("Relay only"))
        XCTAssertTrue(other.label.contains("Active"))

        let revoke = app.buttons["account.grant.4.revoke"]
        reveal(app, revoke)
        revoke.tap()
        confirm(app)

        // The server keeps a revoked connection on the list, marked, with nothing left to do to it.
        XCTAssertTrue(waitForDisappearance(revoke))
        XCTAssertTrue(waitForLabelContaining(other, "Revoked"))
        XCTAssertFalse(other.label.contains("Active"))
        let ownRevoke = app.buttons["account.grant.7.revoke"]
        reveal(app, ownRevoke)
        XCTAssertTrue(ownRevoke.exists, "this phone's own connection is untouched")

        // It is the server's state: the same after the screen is opened again.
        goBack(app)
        reopenAccount(app)
        let otherAgain = app.descendants(matching: .any)["account.grant.4"]
        reveal(app, otherAgain)
        XCTAssertTrue(otherAgain.label.contains("Revoked"))
        XCTAssertFalse(app.buttons["account.grant.4.revoke"].exists)
    }

    func test_minting_a_key_shows_its_token_once_and_the_list_carries_the_key_without_it() throws {
        let app = launch()
        openAccount(app)

        let name = app.textFields["account.key.new.name"]
        reveal(app, name)
        name.tap()
        name.typeText("phone\n")

        // Return dismissed the keyboard and minted; the token sits above the field.
        let token = app.staticTexts["account.key.token"]
        reveal(app, token, above: true)
        let shown = token.label
        XCTAssertTrue(shown.hasPrefix("zmr_"), "the token, in the clear, this once: \(shown)")

        let row = app.descendants(matching: .any)["account.key.3"]
        reveal(app, row)
        XCTAssertTrue(row.label.contains("phone"))
        XCTAssertTrue(row.label.contains("Minted"))
        XCTAssertTrue(row.label.contains("Active"))
        XCTAssertFalse(row.label.contains(shown), "the list carries the fingerprint, never the key")
        XCTAssertTrue(app.buttons["account.key.3.revoke"].exists)

        // Leaving the screen is the last of the token; the key stays.
        goBack(app)
        reopenAccount(app)
        XCTAssertFalse(app.staticTexts["account.key.token"].exists)
        let rowAgain = app.descendants(matching: .any)["account.key.3"]
        reveal(app, rowAgain)
        XCTAssertTrue(rowAgain.label.contains("phone"))
        XCTAssertFalse(rowAgain.label.contains(shown))
    }

    func test_revoking_a_key_keeps_its_row_and_restore_undoes_it() throws {
        let app = launch()
        openAccount(app)

        let row = app.descendants(matching: .any)["account.key.2"]
        reveal(app, row)
        XCTAssertTrue(row.label.contains("laptop scripts"))
        XCTAssertTrue(row.label.contains("Active"))
        let revoke = app.buttons["account.key.2.revoke"]
        reveal(app, revoke)
        revoke.tap()
        confirm(app)

        let restore = app.buttons["account.key.2.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: timeout), "a revoked key's row stays, offering Restore")
        XCTAssertTrue(waitForLabelContaining(row, "Revoked"))

        // Still revoked on a fresh read — then restored, and active again on the row.
        goBack(app)
        reopenAccount(app)
        let rowAgain = app.descendants(matching: .any)["account.key.2"]
        reveal(app, rowAgain)
        XCTAssertTrue(rowAgain.label.contains("Revoked"))
        let restoreAgain = app.buttons["account.key.2.restore"]
        reveal(app, restoreAgain)
        restoreAgain.tap()
        XCTAssertTrue(app.buttons["account.key.2.revoke"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabelContaining(rowAgain, "Active"))
        XCTAssertFalse(rowAgain.label.contains("Revoked"))
    }

    func test_a_relay_only_sign_in_is_refused_a_revoke_in_place() throws {
        let app = launch(["-ZimmerFixtureRelayOnly"])
        openSettings(app)
        XCTAssertTrue(app.staticTexts["settings.signin.privilege"].label.hasPrefix("This connection is relay only"))
        XCTAssertFalse(app.staticTexts["settings.signin.totp"].exists, "the authenticator rows go only to a sign-in acting as you")
        XCTAssertFalse(app.staticTexts["settings.signin.recovery"].exists)
        openAccountFromSettings(app)

        let phone = app.descendants(matching: .any)["account.grant.7"]
        XCTAssertTrue(phone.label.contains("This phone"))
        XCTAssertTrue(phone.label.contains("Relay only"))
        let other = app.descendants(matching: .any)["account.grant.4"]
        reveal(app, other)
        let revoke = app.buttons["account.grant.4.revoke"]
        reveal(app, revoke)
        revoke.tap()
        confirm(app)

        let refusal = app.staticTexts["account.grant.4.error"]
        XCTAssertTrue(refusal.waitForExistence(timeout: timeout))
        XCTAssertEqual(refusal.label, relayOnlyRefusal)
        XCTAssertTrue(revoke.exists, "the row is unchanged")
        XCTAssertTrue(other.label.contains("Active"))

        // Nothing reached the server: the same list when the screen opens again.
        goBack(app)
        reopenAccount(app)
        let otherAgain = app.descendants(matching: .any)["account.grant.4"]
        reveal(app, otherAgain)
        XCTAssertTrue(otherAgain.label.contains("Active"))
        XCTAssertTrue(app.buttons["account.grant.4.revoke"].exists)
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureTab", "more"] + extra
        app.launch()
        return app
    }

    /// From the More tab, until the server has said who this is.
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["more.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: timeout))
        settings.tap()
        XCTAssertTrue(app.staticTexts["settings.signin.email"].waitForExistence(timeout: timeout), "/me is read")
    }

    private func openAccount(_ app: XCUIApplication) {
        openSettings(app)
        openAccountFromSettings(app)
    }

    /// The row on Settings, until the connections list has been read.
    private func openAccountFromSettings(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)["settings.account"]
        reveal(app, row)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account.grant.7"].waitForExistence(timeout: timeout), "the lists are read")
    }

    /// Back on Settings after `goBack`, the row is where it was.
    private func reopenAccount(_ app: XCUIApplication) {
        openAccountFromSettings(app)
    }

    /// Pop API keys & connections, back to Settings.
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: timeout))
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.account"].waitForExistence(timeout: timeout))
    }

    /// The question a revoke asks first. A dialog's button carries no identifier, so it is
    /// found by its title.
    private func confirm(_ app: XCUIApplication, _ title: String = "Revoke") {
        let button = app.sheets.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "the write asks first")
        button.tap()
    }

    /// Scroll until `element` is on screen and below the navigation bar, where a tap lands on
    /// it rather than on the bar (`isHittable` says yes under the bar). A Form row off screen
    /// is not in the accessibility tree, so until it appears the scrolling is blind: on down
    /// the form, or back up it when `above` says the row is behind us (what was just minted
    /// sits above the field). Deliberate drags, a third of a screen each, with a wait after
    /// every one, since a row takes a moment to enter the tree.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, above: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        func barBottom() -> CGFloat {
            app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0
        }
        func placed() -> Bool {
            guard element.exists, !element.frame.isEmpty else { return false }
            return element.frame.minY >= barBottom() && element.frame.maxY <= app.frame.maxY - 24
        }
        for _ in 0..<30 where !placed() {
            let onScreen = element.exists && !element.frame.isEmpty
            let towardTop = onScreen ? element.frame.minY < barBottom() : above
            drag(app, towardTop: towardTop)
            _ = element.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(placed(), "\(element) is scrolled into view", file: file, line: line)
    }

    /// A third of the screen, held at the end so there is no fling to overshoot by. The
    /// finger moves down to bring what is above into view, up for what is below.
    private func drag(_ app: XCUIApplication, towardTop: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.45 : 0.75))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardTop ? 0.75 : 0.45))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
