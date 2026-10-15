import UIKit
import XCTest

/// Slice G, against the `-ZimmerFixture` in-memory Zimmer: a code block's Copy button, block
/// markdown drawn as structure, a link's long-press menu, the composer's "/" typeahead of the
/// session's skills, and the scheduling class and precedence the web page's desktop metadata
/// block edits.
@MainActor
final class TranscriptParityUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    /// The Postgres question (1035) ends on a fenced `sh` block. Copy puts the code on the
    /// pasteboard: pasted into the composer, it is the code and only the code.
    func test_a_code_block_is_copied_and_pastes_as_its_code() throws {
        // Emptied first: the simulator's pasteboard outlives a launch, so a code block copied
        // by an earlier run would otherwise paste without this one's tap.
        UIPasteboard.general.string = ""
        let app = launch(["-ZimmerFixtureOpenSession", "1035"])
        let copy = app.buttons["code.copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: timeout))
        scrollUntilHittable(app, copy)
        XCTAssertEqual(copy.label, "Copy code")
        attachScreenshot(app, named: "code-block")
        // The button reads "Copied" for two seconds, as the web's does, which is less than a
        // tap and an idle wait take here; what landed on the pasteboard is the proof.
        copy.tap()

        let field = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.press(forDuration: 1.2)
        let paste = pasteCommand(app)
        XCTAssertTrue(paste.waitForExistence(timeout: timeout), "the edit menu offers Paste")
        paste.tap()
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "bin/rails db:upgrade -- --target 16"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [pasted], timeout: timeout), .completed, "the pasteboard holds the block's code, without its fences")
    }

    /// The fresh-eyes review (1048) is every kind of block. Its heading, list, table and quote
    /// are drawn as structure, not as the characters that mark them.
    func test_block_markdown_is_drawn_as_structure() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1048"])
        XCTAssertTrue(app.descendants(matching: .any)["detail.message.1"].waitForExistence(timeout: timeout))
        for block in ["markdown.heading", "markdown.list", "markdown.table", "markdown.quote"] {
            XCTAssertTrue(app.descendants(matching: .any)[block].firstMatch.exists, "\(block) is drawn")
        }
        XCTAssertTrue(app.staticTexts["Review of #1293"].exists, "a heading reads without its #s")
        XCTAssertTrue(app.staticTexts["UI tests"].exists, "a table cell is its own text")
        for marks in ["## ", "| ---", "> Fix"] {
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marks)).count, 0, "no \"\(marks)\" left as typed")
        }
        attachScreenshot(app, named: "block-markdown")
    }

    /// A link in an agent's words — here a bare signed URL, the kind a person wants to paste
    /// somewhere else — offers Copy Link on a long press, and what it copies pastes whole.
    func test_a_link_offers_copy_link_on_a_long_press() throws {
        UIPasteboard.general.string = ""
        let url = "https://files.example.com/pr-1293/composer.png?X-Amz-Signature=4f2c9a"
        let app = launch(["-ZimmerFixtureOpenSession", "1048"])
        let paragraph = app.descendants(matching: .any)["markdown.links"].firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: timeout), "a paragraph with links carries the link menu")
        XCTAssertTrue(paragraph.label.contains(url), "a bare URL is kept whole")
        scrollUntilHittable(app, paragraph)
        paragraph.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Open Link"].firstMatch.waitForExistence(timeout: timeout), "the menu opens the link")
        XCTAssertTrue(app.buttons["Share…"].firstMatch.exists, "and shares it")
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy Link")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: timeout), "the long press offers Copy Link")
        attachScreenshot(app, named: "copy-link")
        copy.tap()

        // 1048 is archived, so it has no composer: the copy is pasted into 1035's. The
        // simulator's pasteboard outlives the launch.
        app.terminate()
        let other = launch(["-ZimmerFixtureOpenSession", "1035"])
        let field = other.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.press(forDuration: 1.2)
        let paste = pasteCommand(other)
        XCTAssertTrue(paste.waitForExistence(timeout: timeout), "the edit menu offers Paste")
        paste.tap()
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", url), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [pasted], timeout: timeout), .completed, "the pasteboard holds the whole URL")
    }

    /// 1035 carries three catalog skills; two are a person's to invoke. "/" lists those two,
    /// typing narrows them, and a tap puts the command in the draft.
    func test_typing_a_slash_offers_the_sessions_skills_and_a_tap_inserts_one() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1035"])
        let field = app.descendants(matching: .any)["followup.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("/")

        let openPR = app.buttons["slash.open-pr"]
        let waitForCI = app.buttons["slash.wait-for-ci"]
        XCTAssertTrue(openPR.waitForExistence(timeout: timeout), "the session's invocable skills are offered")
        XCTAssertTrue(waitForCI.exists)
        XCTAssertFalse(app.buttons["slash.zimmer-qa-mobile-screens"].exists, "a skill only an agent invokes is not")
        attachScreenshot(app, named: "slash-typeahead")

        field.typeText("wait-")
        XCTAssertTrue(waitForDisappearance(openPR), "typing narrows the list")
        XCTAssertTrue(waitForCI.exists)
        waitForCI.tap()

        let inserted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "/wait-for-ci "), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [inserted], timeout: timeout), .completed, "the command replaces what was typed after the slash")
        XCTAssertTrue(waitForDisappearance(app.descendants(matching: .any)["slash.list"]), "a space after the command closes the list")
    }

    /// The merge question (1038) is priority by its genesis, at precedence 5.
    func test_the_precedence_and_the_scheduling_class_are_set_from_the_session_menu() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1038"])
        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: timeout))
        let notice = app.descendants(matching: .any)["followup.notice"]

        // Precedence, in an alert that says what it does for a priority session.
        openMenu(app, "Precedence: 5")
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Unused while this session is priority")).firstMatch.exists)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "40")
        app.alerts.buttons["Set"].tap()
        XCTAssertTrue(waitForLabelContaining(notice, "Precedence is now 40."))
        app.buttons["detail.actions"].tap()
        XCTAssertTrue(app.buttons["Precedence: 40"].firstMatch.waitForExistence(timeout: timeout), "the menu says the precedence in force")

        // Spot, as the web select sends it: the class alone, so the precedence just set is the
        // rank it runs at in the spot queue.
        tapMenuItem(app, "Scheduling class: priority")
        tapMenuItem(app, "Spot")
        XCTAssertTrue(waitForLabelContaining(notice, "This session is now spot."))
        app.buttons["detail.actions"].tap()
        XCTAssertTrue(app.buttons["Precedence: 40"].firstMatch.waitForExistence(timeout: timeout), "the demotion kept the precedence")
        app.buttons["Precedence: 40"].firstMatch.tap()
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Higher is worked first")).firstMatch.waitForExistence(timeout: timeout),
                      "the note follows the class")
        app.alerts.buttons["Cancel"].tap()

        // Derive it: the class chosen is cleared, and the genesis's priority is back.
        openMenu(app, "Scheduling class: spot")
        tapMenuItem(app, "Derive it")
        XCTAssertTrue(waitForLabelContaining(notice, "This session is now priority."))

        openMenu(app, "Scheduling class: priority")
        XCTAssertTrue(app.buttons["Derive it (priority)"].firstMatch.waitForExistence(timeout: timeout),
                      "Derive it is the choice, and names the class the genesis gives")
        attachScreenshot(app, named: "scheduling-class")
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + arguments
        app.launch()
        return app
    }

    /// The page opens at its newest message; swipe toward `element` until it can be tapped.
    private func scrollUntilHittable(_ app: XCUIApplication, _ element: XCUIElement) {
        // Below the navigation bar and the section strip pinned under it too: isHittable says
        // yes under them, where a tap lands on them.
        func inView() -> Bool {
            guard element.exists, !element.frame.isEmpty, element.isHittable else { return false }
            let bar = app.navigationBars.firstMatch
            let strip = app.descendants(matching: .any)["detail.sections"]
            // And above the composer and its quick replies, which isHittable can also miss.
            let field = app.descendants(matching: .any)["followup.field"]
            let bottom = field.exists ? field.frame.minY - 50 : app.frame.maxY
            return element.frame.minY >= max(bar.exists ? bar.frame.maxY : 0, strip.exists ? strip.frame.maxY : 0)
                && element.frame.maxY <= bottom
        }
        for _ in 0..<8 where !inView() {
            if element.frame.midY < app.frame.midY { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(inView(), "scrolled into view")
    }

    /// The edit menu's Paste: a menu item on current iOS, a button on some runtimes.
    private func pasteCommand(_ app: XCUIApplication) -> XCUIElement {
        let item = app.menuItems["Paste"].firstMatch
        if item.waitForExistence(timeout: 3) { return item }
        return app.buttons["Paste"].firstMatch
    }

    private func openMenu(_ app: XCUIApplication, _ item: String) {
        let menu = app.buttons["detail.actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()
        tapMenuItem(app, item)
    }

    private func tapMenuItem(_ app: XCUIApplication, _ item: String) {
        let button = app.buttons[item].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "the menu offers \(item)")
        button.tap()
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForLabelContaining(_ element: XCUIElement, _ text: String) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
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
