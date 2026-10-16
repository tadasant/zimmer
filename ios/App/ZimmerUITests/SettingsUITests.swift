import XCTest

/// Settings: the web page's Session Defaults, Experimental and MCP Apps sections, against the
/// `-ZimmerFixture` in-memory Zimmer. Every assertion is on state that stays — a status
/// line, a switch's value, a tick after reopening — never on a toast, which is gone before
/// a tap and an idle wait are over.
@MainActor
final class SettingsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_experimental_toggles_say_their_state_and_a_flip_persists() throws {
        let app = launch()
        openSettings(app)

        let search = app.staticTexts["settings.experimental.mcp_tool_search.status"]
        reveal(app, search)
        XCTAssertEqual(search.label, "MCP tool search is ON (recommended default).")
        let clones = app.staticTexts["settings.experimental.warm_clone_pool_active_roots.status"]
        reveal(app, clones)
        XCTAssertEqual(clones.label, "Warm clones for every active root is OFF (recommended default).")
        let router = app.staticTexts["settings.experimental.warm_router_process.status"]
        reveal(app, router)
        XCTAssertEqual(router.label, "Warm Quick Router process is OFF (recommended default).")

        // A flip saves at once; the status line follows the server's answer.
        let toggle = app.switches["settings.experimental.warm_router_process"]
        reveal(app, toggle)
        tapSwitch(toggle)
        XCTAssertTrue(waitForLabel(router, "Warm Quick Router process is ON."))
        XCTAssertEqual(toggle.value as? String, "1")
        // Back up to the first row: a Form row scrolled off is not in the accessibility tree.
        reveal(app, search, above: true)
        XCTAssertEqual(search.label, "MCP tool search is ON (recommended default).", "the other toggles are untouched")

        closeSettings(app)
        openSettings(app)
        let again = app.staticTexts["settings.experimental.warm_router_process.status"]
        reveal(app, again)
        XCTAssertEqual(again.label, "Warm Quick Router process is ON.", "the change was stored")
        XCTAssertEqual(app.switches["settings.experimental.warm_router_process"].value as? String, "1")
    }

    func test_changing_the_default_model_and_saving_updates_the_banner() throws {
        let app = launch()
        openSettings(app)

        let banner = app.staticTexts["settings.defaults.banner"]
        reveal(app, banner)
        XCTAssertEqual(banner.label, "No global override set — using the built-in default (Claude Code / opus).")
        let save = app.buttons["settings.defaults.save"]
        reveal(app, save)
        XCTAssertFalse(save.isEnabled, "nothing to save until something changes")

        let picker = app.descendants(matching: .any)["settings.defaults.model"]
        reveal(app, picker)
        picker.tap()
        let sonnet = app.buttons["sonnet"].firstMatch
        XCTAssertTrue(sonnet.waitForExistence(timeout: timeout), "the Claude Code models are offered")
        sonnet.tap()
        reveal(app, save)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(waitForLabel(banner, "Active global default: Claude Code / sonnet"))

        closeSettings(app)
        openSettings(app)
        let after = app.staticTexts["settings.defaults.banner"]
        reveal(app, after)
        XCTAssertEqual(after.label, "Active global default: Claude Code / sonnet", "the override was stored")
    }

    func test_mcp_apps_on_with_a_server_ticked_is_how_settings_reopens() throws {
        let app = launch()
        openSettings(app)

        let master = app.switches["settings.mcpapps.enabled"]
        reveal(app, master)
        XCTAssertEqual(master.value as? String, "0", "off by default")
        tapSwitch(master)
        XCTAssertEqual(master.value as? String, "1")
        let linear = app.buttons["settings.mcpapps.server.linear"]
        reveal(app, linear)
        linear.tap()
        XCTAssertTrue(linear.isSelected)
        let save = app.buttons["settings.mcpapps.save"]
        reveal(app, save)
        save.tap()
        XCTAssertTrue(app.staticTexts["settings.mcpapps.saved"].waitForExistence(timeout: timeout), "the server answered")

        closeSettings(app)
        openSettings(app)
        let masterAgain = app.switches["settings.mcpapps.enabled"]
        reveal(app, masterAgain)
        XCTAssertEqual(masterAgain.value as? String, "1", "the switch was stored")
        let linearAgain = app.buttons["settings.mcpapps.server.linear"]
        reveal(app, linearAgain)
        XCTAssertTrue(linearAgain.isSelected, "the tick was stored")
        let github = app.buttons["settings.mcpapps.server.github"]
        reveal(app, github)
        XCTAssertFalse(github.isSelected, "only the ticked server is allowed")
    }

    func test_a_relay_only_sign_in_is_refused_mcp_apps_in_place() throws {
        let app = launch(["-ZimmerFixtureRelayOnly"])
        openSettings(app)

        let master = app.switches["settings.mcpapps.enabled"]
        reveal(app, master)
        tapSwitch(master)
        XCTAssertEqual(master.value as? String, "1")
        let save = app.buttons["settings.mcpapps.save"]
        reveal(app, save)
        save.tap()

        let refusal = app.staticTexts["settings.mcpapps.error"]
        XCTAssertTrue(refusal.waitForExistence(timeout: timeout))
        XCTAssertEqual(refusal.label, "This sign-in may not act as you; sign in again and allow acting as you to change MCP Apps")
        XCTAssertEqual(master.value as? String, "1", "the controls are left as they were set")
        XCTAssertFalse(app.staticTexts["settings.mcpapps.saved"].exists)

        // Nothing reached the server: the switch is off when Settings opens again.
        closeSettings(app)
        openSettings(app)
        let masterAgain = app.switches["settings.mcpapps.enabled"]
        reveal(app, masterAgain)
        XCTAssertEqual(masterAgain.value as? String, "0")
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureTab", "more"] + extra
        app.launch()
        return app
    }

    /// From the More tab, until the row has been read.
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["more.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: timeout))
        settings.tap()
        XCTAssertTrue(app.staticTexts["settings.defaults.banner"].waitForExistence(timeout: timeout), "the server's row is read")
    }

    private func closeSettings(_ app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: timeout))
        done.tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["settings.server"]))
    }

    /// Scroll until `element` is on screen and below the navigation bar, where a tap lands on
    /// it rather than on the bar (`isHittable` says yes under the bar). A Form row off screen
    /// is not in the accessibility tree, so until it appears the scrolling is blind: down the
    /// form, or back up it when the row is known to be `above` what is on screen.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, above: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        func barBottom() -> CGFloat {
            app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0
        }
        func placed() -> Bool {
            guard element.exists, !element.frame.isEmpty else { return false }
            return element.frame.minY >= barBottom() && element.frame.maxY <= app.frame.maxY - 24
        }
        for _ in 0..<14 where !placed() {
            let onScreen = element.exists && !element.frame.isEmpty
            let underTheBar = onScreen && element.frame.minY < barBottom()
            scroll(app, down: underTheBar || (!onScreen && above))
        }
        XCTAssertTrue(placed(), "\(element) is scrolled into view", file: file, line: line)
    }

    /// A third of the screen, held at the end so there is no fling to overshoot by.
    private func scroll(_ app: XCUIApplication, down: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.45 : 0.75))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.75 : 0.45))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }

    /// A Form toggle's switch is tapped on its right edge, where the control is.
    private func tapSwitch(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
