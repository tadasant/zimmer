import XCTest

/// Creating, editing and deleting a trigger from the app, against the `-ZimmerFixture`
/// in-memory Zimmer: the form sheet off the list's plus and the page's Edit, the page's
/// Delete behind the web's confirmation, and a refusal shown in place. Every assertion is on
/// what persists — the list and the page — never on a toast.
@MainActor
final class TriggerEditorUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    /// A schedule trigger is created from the list: its name, an every-6-hours condition, its
    /// root and its prompt are entered, and the page it lands on and the list behind it read them.
    func test_a_schedule_trigger_is_created_from_the_list_and_read_back() throws {
        let app = launch(["-ZimmerFixtureTab", "triggers"])
        let add = app.buttons["trigger.new"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        let name = app.textFields["trigger.form.name"]
        XCTAssertTrue(name.waitForExistence(timeout: timeout))
        name.tap()
        name.typeText("Hourly inbox sweep")

        // The web's new page starts with one Slack condition; make it a schedule.
        choose(app, "trigger.form.condition.0.type", "Schedule - Time-based (recurring or one-time)")
        let interval = app.textFields["trigger.form.condition.0.interval"]
        XCTAssertTrue(reveal(app, interval), "the frequency fields follow the type")
        XCTAssertEqual(interval.value as? String, "1", "the web's default")
        replace(interval, with: "6")
        choose(app, "trigger.form.condition.0.unit", "hours")
        XCTAssertFalse(app.textFields["trigger.form.condition.0.time"].exists, "hours name no time of day")

        choose(app, "trigger.form.agentRoot", "Zimmer")
        let prompt = app.descendants(matching: .any)["trigger.form.prompt"]
        XCTAssertTrue(reveal(app, prompt))
        prompt.tap()
        prompt.typeText("Sweep the inbox and file what matters.")
        app.buttons["trigger.form.save"].tap()

        // The page it made, as the web lands on it.
        XCTAssertTrue(app.navigationBars["Hourly inbox sweep"].waitForExistence(timeout: timeout), "the trigger's page opens with the name entered")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Every 6 hours")).firstMatch.waitForExistence(timeout: timeout),
                      "the condition as entered, in the server's words")
        let root = app.descendants(matching: .any)["trigger.detail.agentRoot"]
        XCTAssertTrue(reveal(app, root))
        XCTAssertTrue(root.label.contains("zimmer"), "the root chosen: \(root.label)")
        let page = app.descendants(matching: .any)["trigger.detail.prompt"]
        XCTAssertTrue(reveal(app, page))
        XCTAssertEqual(page.label, "Sweep the inbox and file what matters.")

        // And the list behind it.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.descendants(matching: .any)["trigger.8"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "listed, first, as the server lists newest first")
        XCTAssertTrue(row.label.contains("Hourly inbox sweep"))
        XCTAssertTrue(row.label.contains("Every 6 hours"))
    }

    /// Edit from the page: the name and the prompt change, and the page and the list say so.
    func test_a_triggers_name_and_prompt_are_edited_from_its_page() throws {
        let app = launch(["-ZimmerFixtureTrigger", "5"])
        XCTAssertTrue(app.navigationBars["Nightly dependency sweep"].waitForExistence(timeout: timeout))
        app.buttons["trigger.detail.actions"].tap()
        app.buttons["trigger.edit"].firstMatch.tap()
        let name = app.textFields["trigger.form.name"]
        XCTAssertTrue(name.waitForExistence(timeout: timeout))
        XCTAssertEqual(name.value as? String, "Nightly dependency sweep", "the form opens on the stored settings")
        let time = app.textFields["trigger.form.condition.0.time"]
        XCTAssertTrue(reveal(app, time))
        XCTAssertEqual(time.value as? String, "02:00", "and the stored condition's")
        XCTAssertTrue(reveal(app, name, upward: false))
        replace(name, with: "Nightly dependency sweep (quiet)")

        let prompt = app.descendants(matching: .any)["trigger.form.prompt"]
        XCTAssertTrue(reveal(app, prompt))
        // The cursor lands where the tap does; the trailing corner is after the last word.
        prompt.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.9)).tap()
        prompt.typeText(" Say what you skipped.")
        app.buttons["trigger.form.save"].tap()

        XCTAssertTrue(app.navigationBars["Nightly dependency sweep (quiet)"].waitForExistence(timeout: timeout), "the page has the name entered")
        let page = app.descendants(matching: .any)["trigger.detail.prompt"]
        XCTAssertTrue(reveal(app, page))
        XCTAssertTrue(page.label.hasSuffix("Say what you skipped."), "and the prompt as edited: \(page.label)")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.descendants(matching: .any)["trigger.5"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabelContaining(row, "Nightly dependency sweep (quiet)"), "the list reads the saved name")
    }

    /// A blank name is refused by the server in its words, in place, and nothing is created.
    func test_a_refusal_is_shown_in_place_and_nothing_is_created() throws {
        let app = launch(["-ZimmerFixtureTab", "triggers"])
        let add = app.buttons["trigger.new"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        let name = app.textFields["trigger.form.name"]
        XCTAssertTrue(name.waitForExistence(timeout: timeout))
        choose(app, "trigger.form.agentRoot", "Zimmer")
        let prompt = app.descendants(matching: .any)["trigger.form.prompt"]
        XCTAssertTrue(reveal(app, prompt))
        prompt.tap()
        prompt.typeText("Answer the thread.")
        app.buttons["trigger.form.save"].tap()

        let refusal = app.descendants(matching: .any)["trigger.form.error"]
        XCTAssertTrue(refusal.waitForExistence(timeout: timeout), "the refusal heads the form")
        XCTAssertTrue(refusal.label.contains("prohibited this trigger from being saved"), "the web form's heading: \(refusal.label)")
        XCTAssertTrue(refusal.label.contains("Name can't be blank"), "the server's reason")
        XCTAssertTrue(refusal.label.contains("must include channel_id for Slack conditions"), "and the Slack condition's")
        XCTAssertTrue(name.exists, "still on the form, with what was typed")

        app.buttons["Cancel"].firstMatch.tap()
        let nightly = app.descendants(matching: .any)["trigger.5"].firstMatch
        XCTAssertTrue(nightly.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.descendants(matching: .any)["trigger.8"].exists, "nothing was created")
    }

    /// Delete from the page, after the web's confirmation: the list no longer has it.
    func test_a_trigger_is_deleted_after_confirming() throws {
        let app = launch(["-ZimmerFixtureTrigger", "6"])
        XCTAssertTrue(app.navigationBars["Slack #zimmer mentions"].waitForExistence(timeout: timeout))
        app.buttons["trigger.detail.actions"].tap()
        app.buttons["trigger.delete"].firstMatch.tap()
        // The web page's confirmation, word for word. In the sheet, by its label: a
        // confirmation's identifier does not reach the sheet.
        let confirm = app.sheets.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Are you sure you want to delete this trigger?"].exists)
        confirm.tap()

        XCTAssertTrue(app.navigationBars["Triggers"].waitForExistence(timeout: timeout), "back on the list")
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["trigger.6"].firstMatch), "gone from the list")
        XCTAssertTrue(app.descendants(matching: .any)["trigger.5"].firstMatch.exists, "the others stay")
        XCTAssertTrue(app.descendants(matching: .any)["trigger.7"].firstMatch.exists)
    }

    // MARK: - Helpers

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }

    /// Scroll the form until `element` is on screen and below the navigation bar — a tap on a
    /// row still under the bar lands on the bar — and return whether it is.
    /// `upward` is which way to look for a row that is not in the tree: further down the form
    /// (the default), or back up past the bar.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, upward: Bool = true) -> Bool {
        func belowTheBar() -> Bool {
            guard element.exists, !element.frame.isEmpty else { return false }
            let bar = app.navigationBars.firstMatch
            let top = bar.exists ? bar.frame.maxY : 0
            return element.frame.minY >= top && app.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.maxY))
        }
        // A row off screen is not in the accessibility tree, so look for it after every swipe.
        for _ in 0..<8 where !belowTheBar() {
            let aboveTheBar = element.exists && !element.frame.isEmpty && element.frame.minY < app.navigationBars.firstMatch.frame.maxY
            if aboveTheBar || (!element.exists && !upward) { app.swipeDown() } else { app.swipeUp() }
        }
        return belowTheBar()
    }

    /// Pick an option from one of the form's menu pickers, by the option's words.
    private func choose(_ app: XCUIApplication, _ identifier: String, _ option: String) {
        let picker = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(reveal(app, picker), "the picker \(identifier) is on screen")
        picker.tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "the option \(option) is offered")
        item.tap()
    }

    /// Replace a single-line field's text: the cursor goes after the last character, which a tap
    /// past the end of a short value puts it at, then as many deletes as there are characters.
    private func replace(_ field: XCUIElement, with text: String) {
        let current = field.value as? String ?? ""
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }
}
