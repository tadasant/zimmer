import XCTest

/// CarPlay fit from the phone, against the `-ZimmerFixture` in-memory Zimmer: the board's filter
/// keeps what can be done from a car, and the session page's menu marks a session by hand.
@MainActor
final class CarplayFitUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_filter_keeps_what_can_be_done_from_the_car() throws {
        let app = launch(["-ZimmerFixtureBoard", "all"])
        let more = app.buttons["filter.more"]
        XCTAssertTrue(more.waitForExistence(timeout: timeout))
        XCTAssertTrue(row(app, 1044).waitForExistence(timeout: timeout), "the parity audit needs input")

        more.tap()
        let picker = app.buttons["filters.carplayFit"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: timeout))
        // The section sits below the fold of the sheet.
        for _ in 0..<4 where !picker.isHittable { app.swipeUp() }
        picker.tap()
        let notLaptop = app.buttons["Not laptop-only"].firstMatch
        XCTAssertTrue(notLaptop.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "carplay-fit-filter-choices")
        notLaptop.tap()
        // A menu picker shows its choice as its value on some iOS releases, in its label on others.
        let chosen = expectation(for: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Not laptop-only", "Not laptop-only"), evaluatedWith: picker)
        XCTAssertEqual(XCTWaiter().wait(for: [chosen], timeout: timeout), .completed, "the picker shows the choice")
        attachScreenshot(app, named: "carplay-fit-filter")
        app.buttons["filters.apply"].tap()

        XCTAssertTrue(waitForDisappearance(row(app, 1044)), "a long read waits for the laptop")
        XCTAssertTrue(row(app, 1038).exists, "a merge decision can be made from the car")
        XCTAssertTrue(row(app, 1035).exists, "a session not judged yet stays")
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["filter.summary"], "Not laptop-only"))
        attachScreenshot(app, named: "carplay-fit-board")
    }

    func test_the_session_menu_marks_the_carplay_fit_by_hand() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1035"])
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: timeout))

        app.buttons["detail.actions"].tap()
        let item = menuItem(app, beginningWith: "CarPlay fit")
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "the menu offers CarPlay fit")
        XCTAssertTrue(item.label.contains("untagged"), "it says no mark stands: \(item.label)")
        item.tap()
        let laptop = menuItem(app, beginningWith: "Laptop only")
        XCTAssertTrue(laptop.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "carplay-fit-menu")
        laptop.tap()
        let manual = app.buttons["Manual steps"].firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: timeout), "the laptop side offers its reasons")
        attachScreenshot(app, named: "carplay-fit-reasons")
        manual.tap()
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["followup.notice"], "Marked Laptop only (manual steps)"))

        // The menu now says what stands, with who set it.
        app.buttons["detail.actions"].tap()
        let marked = menuItem(app, beginningWith: "CarPlay fit: Laptop only")
        XCTAssertTrue(marked.waitForExistence(timeout: timeout), "the menu names the mark in force")
        XCTAssertTrue(marked.label.contains("human"), "a mark from the app is a human one: \(marked.label)")
        attachScreenshot(app, named: "carplay-fit-marked")

        // And clears it.
        marked.tap()
        let clear = app.buttons["Clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: timeout))
        clear.tap()
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["followup.notice"], "CarPlay fit cleared"))
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    private func row(_ app: XCUIApplication, _ id: Int) -> XCUIElement {
        app.descendants(matching: .any)["session.row.\(id)"]
    }

    /// A menu item whose title is followed by a second line, or a mark, matched on its start.
    private func menuItem(_ app: XCUIApplication, beginningWith title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
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
