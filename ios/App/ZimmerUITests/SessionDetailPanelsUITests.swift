import UIKit
import XCTest

/// The session page's detail (iOS parity G16), against the `-ZimmerFixture` in-memory
/// Zimmer: the goal named from the catalog and picked from it, the goal check's delegated
/// sessions, the hierarchy's origin, genesis and "drawn under" rows, the human messages split
/// here from elsewhere with the capture gap, and each MCP server's connection.
@MainActor
final class SessionDetailPanelsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_goal_is_named_from_the_catalog_and_picked_from_it() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        // 1038 stores the catalog goal's words; the page names it.
        let name = app.staticTexts["detail.goal.name"]
        XCTAssertTrue(name.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForLabel(name, "Open Reviewed Green PR"))

        // The menu's Modify Goal opens the picker: a catalog goal by name.
        openMenu(app, "Modify Goal")
        let question = app.descendants(matching: .any)["goal.option.codebase-question"]
        XCTAssertTrue(question.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "goal-picker")
        // The "Goal: Codebase Question" toast is up for under the time a tap and an idle wait
        // take here (a CI recording shows it); the name the row now reads is the proof.
        question.tap()
        XCTAssertTrue(waitForLabel(name, "Codebase Question"))

        // The row's Edit opens it too: your own words, which name no catalog goal.
        let edit = app.buttons["detail.goal.edit"]
        scrollUntilHittable(app, edit)
        edit.tap()
        let field = app.descendants(matching: .any)["goal.custom.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Merge once the reviewer signs off.")
        app.buttons["goal.custom.save"].tap()
        XCTAssertTrue(waitForDisappearance(name), "free text has no catalog name")
        XCTAssertTrue(app.staticTexts["Merge once the reviewer signs off."].waitForExistence(timeout: timeout))
    }

    /// The goal's words are copied from a long press, as a whole: pasted into the composer,
    /// they are the words and only the words.
    func test_the_goals_words_are_copied_from_a_long_press() throws {
        UIPasteboard.general.string = ""
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        let words = app.staticTexts["Unmerged PR is open and CI is green."]
        XCTAssertTrue(words.waitForExistence(timeout: timeout))
        scrollUntilHittable(app, words)
        words.press(forDuration: 1.2)
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: timeout), "the long press offers Copy")
        copy.tap()

        let field = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.press(forDuration: 1.2)
        let paste = pasteCommand(app)
        XCTAssertTrue(paste.waitForExistence(timeout: timeout), "the edit menu offers Paste")
        paste.tap()
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Unmerged PR is open and CI is green."), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [pasted], timeout: timeout), .completed, "the pasteboard holds the goal's words")
    }

    func test_the_goal_check_opens_the_session_whose_prs_it_judged() throws {
        // The router recorded no PR of its own; it is judged on 1044's, which it spawned.
        let app = launch(["-ZimmerFixtureOpenSession", "1040"])
        let tally = app.staticTexts["detail.goalcheck.tally"]
        XCTAssertTrue(tally.waitForExistence(timeout: timeout))
        XCTAssertTrue(tally.label.contains("Open Reviewed Green PR"))
        let delegate = app.descendants(matching: .any)["goalcheck.delegate.1044"]
        XCTAssertTrue(delegate.waitForExistence(timeout: timeout))
        attachScreenshot(app, named: "goal-check-delegated")
        scrollUntilHittable(app, delegate)
        delegate.tap()
        XCTAssertTrue(app.navigationBars["#1044"].waitForExistence(timeout: timeout), "the spawned session opens")
    }

    func test_the_hierarchy_marks_and_the_human_messages_here_and_elsewhere() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1044", "-ZimmerFixtureOpenPanels"])
        let origin = app.descendants(matching: .any)["hierarchy.node.1040"]
        XCTAssertTrue(origin.waitForExistence(timeout: timeout))
        XCTAssertTrue(origin.label.contains("origin"), "the spawn origin is marked")
        XCTAssertTrue(origin.label.contains("slack · priority"), "genesis and class, as the web pill")
        XCTAssertTrue(app.descendants(matching: .any)["hierarchy.node.1044"].label.contains("this session"))
        XCTAssertTrue(app.descendants(matching: .any)["hierarchy.node.1049"].label.contains("drawn under #1044"))

        // The capture gap, then each message, here or elsewhere.
        let gap = app.descendants(matching: .any)["humanmessages.gap.slack"]
        XCTAssertTrue(gap.waitForExistence(timeout: timeout))
        XCTAssertTrue(gap.label.contains("Capture is not configured for Slack"))
        XCTAssertTrue(labelled(app, "1 message in this session · 1 elsewhere").exists, "the folded row's counts")
        XCTAssertTrue(app.descendants(matching: .any)["humanmessage.here"].exists)
        attachScreenshot(app, named: "panels")
        let saidIn = app.descendants(matching: .any)["humanmessage.saidin.1040"]
        XCTAssertTrue(saidIn.waitForExistence(timeout: timeout))
        scrollUntilHittable(app, saidIn)
        saidIn.tap()
        XCTAssertTrue(app.navigationBars["#1040"].waitForExistence(timeout: timeout), "the session it was said in opens")
    }

    func test_the_human_messages_open_from_their_folded_row() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        // The closed row is the disclosure's button, so it is found by what it says.
        let summary = labelled(app, "1 message in this session · 0 elsewhere in the hierarchy")
        XCTAssertTrue(summary.waitForExistence(timeout: timeout))
        let here = app.descendants(matching: .any)["humanmessage.here"]
        XCTAssertFalse(here.exists, "folded until opened")
        scrollUntilHittable(app, summary)
        summary.tap()
        XCTAssertTrue(here.waitForExistence(timeout: timeout))
    }

    func test_each_mcp_server_says_how_its_connection_stands() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1044", "-ZimmerFixtureOpenPanels"])
        // Found by what each says: the failed one is a button around its chip.
        let linear = labelled(app, "linear: Failed")
        XCTAssertTrue(linear.waitForExistence(timeout: timeout))
        XCTAssertTrue(labelled(app, "playwright-custom: Connected").exists)
        XCTAssertTrue(labelled(app, "zimmer-self-session: Pending connection, added by Zimmer").exists)

        // A failed server's error, a tap away.
        scrollUntilHittable(app, linear)
        linear.tap()
        let error = app.staticTexts["mcp.error.linear"]
        XCTAssertTrue(error.waitForExistence(timeout: timeout))
        XCTAssertTrue(error.label.contains("401 Unauthorized"))
        attachScreenshot(app, named: "mcp-error")

        // Edit opens the MCP server checklist.
        let edit = app.buttons["detail.mcp.edit"]
        scrollUntilHittable(app, edit)
        edit.tap()
        XCTAssertTrue(app.buttons["catalog.save"].waitForExistence(timeout: timeout))
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    private func labelled(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openMenu(_ app: XCUIApplication, _ item: String) {
        let menu = app.buttons["detail.actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "the session menu offers \(item)")
        button.tap()
    }

    /// The page opens at its newest message, so what is asked for may be above or below.
    private func scrollUntilHittable(_ app: XCUIApplication, _ element: XCUIElement) {
        // Ask for hittability only of an element on the page with a frame: asking it of one the
        // lazy list has not laid out throws rather than answering no.
        // And below the navigation bar: isHittable says yes for an element still under it, where
        // a tap lands on the bar.
        func inView() -> Bool {
            guard element.exists, !element.frame.isEmpty, element.isHittable else { return false }
            let bar = app.navigationBars.firstMatch
            return element.frame.minY >= (bar.exists ? bar.frame.maxY : 0)
        }
        for _ in 0..<8 where !inView() {
            // Not laid out yet means above: the page opens at its newest message, under the panels.
            if !element.exists || element.frame.isEmpty || element.frame.midY < app.frame.midY {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(inView(), "\(element) comes into view")
    }

    /// The edit menu's Paste: a menu item on current iOS, a button on some runtimes.
    private func pasteCommand(_ app: XCUIApplication) -> XCUIElement {
        let item = app.menuItems["Paste"].firstMatch
        if item.waitForExistence(timeout: 3) { return item }
        return app.buttons["Paste"].firstMatch
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
