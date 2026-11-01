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
        // The section sits below the fold, and a Form builds its rows as they scroll into view.
        XCTAssertTrue(app.buttons["filters.apply"].waitForExistence(timeout: timeout))
        let shown = scrollPickerBelowTheBar(app)
        XCTAssertTrue(app.buttons["filters.apply"].exists, "the Filters sheet is still up after scrolling it")
        XCTAssertNotNil(shown, "the Filters sheet offers CarPlay fit, on screen and clear of the bar")
        guard let shown else { return }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: shown.midX, dy: shown.midY)).tap()
        let notLaptop = menuItem(app, titled: "Not laptop-only")
        XCTAssertTrue(notLaptop.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "carplay-fit-filter-choices")
        notLaptop.tap()
        // A menu picker shows its choice as its value on some iOS releases, in its label on others.
        // The condition sits in the query, so no element is held across reads (see `pickerFrame`).
        let chosen = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
            "filters.carplayFit", "Not laptop-only", "Not laptop-only")).firstMatch
        XCTAssertTrue(chosen.waitForExistence(timeout: timeout), "the picker shows the choice")
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
        let item = menuItem(app, titled: "CarPlay fit")
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "the menu offers CarPlay fit")
        item.tap()
        XCTAssertTrue(menuItem(app, titled: "Now: untagged").waitForExistence(timeout: timeout), "it says no mark stands")
        let laptop = menuItem(app, titled: "Laptop only")
        XCTAssertTrue(laptop.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "carplay-fit-menu")
        laptop.tap()
        let manual = menuItem(app, titled: "Manual steps")
        XCTAssertTrue(manual.waitForExistence(timeout: timeout), "the laptop side offers its reasons")
        attachScreenshot(app, named: "carplay-fit-reasons")
        manual.tap()
        XCTAssertTrue(waitForLabelContaining(app.descendants(matching: .any)["followup.notice"], "Marked Laptop only (manual steps)"))

        // The menu now says what stands, with who set it.
        app.buttons["detail.actions"].tap()
        let marked = menuItem(app, titled: "CarPlay fit: Laptop only")
        XCTAssertTrue(marked.waitForExistence(timeout: timeout), "the menu names the mark in force")
        marked.tap()
        let standing = menuItem(app, beginningWith: "Now: Laptop only (manual steps) · human")
        XCTAssertTrue(standing.waitForExistence(timeout: timeout), "a mark from the app is a human one")
        attachScreenshot(app, named: "carplay-fit-marked")

        // And clears it.
        let clear = menuItem(app, titled: "Clear")
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

    /// The CarPlay fit picker's frame, read in one snapshot of a fresh query, or nil while it is
    /// not in the tree. A fresh query each time because an `XCUIElement` pins the type it first
    /// resolved to (here Button), and this menu-style Picker can read as another type on a later
    /// query, as its menu rows do (see `menuItem`): a held element then answers `exists` and
    /// fails its next lookup with "No matches found". One snapshot because `exists` then
    /// `.frame` is two lookups the Form can rebuild the row between. And not `isHittable`, which
    /// for a row in the tree but not laid out fails the test ("Activation point invalid") instead
    /// of answering no. A board-shard run on main died of `isHittable`; a held element died of
    /// the type it had pinned.
    private func pickerFrame(_ app: XCUIApplication) -> CGRect? {
        let picker = app.descendants(matching: .any).matching(identifier: "filters.carplayFit").firstMatch
        guard let frame = try? picker.snapshot().frame, !frame.isEmpty else { return nil }
        return frame
    }

    /// The bottom of the Filters sheet's own bar, not the board's behind it, when it can be told apart.
    private func barBottom(_ app: XCUIApplication) -> CGFloat {
        if let sheetBar = try? app.navigationBars["Filters"].snapshot() { return sheetBar.frame.maxY }
        return (try? app.navigationBars.firstMatch.snapshot())?.frame.maxY ?? 0
    }

    /// A Form builds its rows as they scroll into view: swipe up until the picker is on screen
    /// and clear of the bar, back down if a swipe carried it under the bar. Its frame, or nil.
    private func scrollPickerBelowTheBar(_ app: XCUIApplication) -> CGRect? {
        let screen = app.frame
        for _ in 0..<10 {
            let top = barBottom(app)
            if let frame = pickerFrame(app) {
                if frame.minY >= top && screen.contains(CGPoint(x: frame.midX, y: frame.maxY)) { return frame }
                if frame.minY < top { app.swipeDown(velocity: .slow); continue }
            }
            app.swipeUp(velocity: .slow)
        }
        return nil
    }

    /// A menu item by its title, whatever element type it reads as. A row of a menu-style
    /// Picker, or a submenu, carries a legacy Button type and a modern PopUpButton one, and
    /// XCUITest resolves the mismatch either way from one run to the next: a board-shard run
    /// on main found "Not laptop-only" as a Button, screenshotted the open menu, and then
    /// retried the tap for forty seconds against a PopUpButton that `app.buttons` never matched.
    private func menuItem(_ app: XCUIApplication, titled title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// A menu item whose title is followed by a second line, or a mark, matched on its start.
    private func menuItem(_ app: XCUIApplication, beginningWith title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
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
