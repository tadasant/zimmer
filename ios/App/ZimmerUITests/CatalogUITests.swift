import XCTest

/// Slice 4: the full new-session form, and a session's model and skills, against the
/// `-ZimmerFixture` in-memory Zimmer.
@MainActor
final class CatalogUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_full_form_starts_a_session_on_the_roots_defaults_and_opens_it() throws {
        let app = launch(["-ZimmerFixtureNewSession"])
        let prompt = app.descendants(matching: .any)["newsession.prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: timeout))
        // The root's defaults are already chosen.
        // The row's value, wherever the form puts it (its label or its value).
        let chosen = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '2 chosen' OR value CONTAINS '2 chosen'")).firstMatch
        XCTAssertTrue(chosen.waitForExistence(timeout: timeout), "the root's two default skills are chosen")
        prompt.tap()
        prompt.typeText("Rotate the staging deploy key")
        app.buttons["newsession.create"].tap()

        let title = app.staticTexts["detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: timeout))
        XCTAssertEqual(title.label, "Rotate the staging deploy key")
        XCTAssertTrue(app.descendants(matching: .any)["detail.metadata"].label.contains("opus"))
    }

    func test_a_sessions_model_and_skills_change_from_its_menu() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        let actions = app.buttons["detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: timeout))

        actions.tap()
        app.buttons["detail.model"].tap()
        let sonnet = app.buttons["model.sonnet"]
        XCTAssertTrue(sonnet.waitForExistence(timeout: timeout))
        sonnet.tap()
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["detail.metadata"], "sonnet"))

        actions.tap()
        app.buttons["MCP Servers, Skills, Hooks, Plugins"].firstMatch.tap()
        app.buttons["Skills (0)"].firstMatch.tap()
        let skill = app.buttons["catalog.item.open-pr"]
        XCTAssertTrue(skill.waitForExistence(timeout: timeout))
        skill.tap()
        app.buttons["catalog.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["followup.notice"].waitForExistence(timeout: timeout), "the change is confirmed")

        actions.tap()
        app.buttons["MCP Servers, Skills, Hooks, Plugins"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Skills (1)"].firstMatch.waitForExistence(timeout: timeout))
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }
}
