import XCTest

/// Photos and files from the Quick Router bar on the board, against the `-ZimmerFixture`
/// in-memory Zimmer: the paperclip is in the bar itself, not only in the sheet behind the
/// sparkles. The system pickers cannot be driven from a UI test, so
/// `-ZimmerFixtureQuickRouterAttachment` starts the bar with a file attached, and the
/// paperclip's choices are checked on their own.
@MainActor
final class QuickRouterAttachmentsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_bar_has_a_paperclip_that_offers_photos_and_files() throws {
        let app = launch()
        let attach = app.buttons["quickrouter.bar.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: timeout), "the bar has its own paperclip")
        let field = app.descendants(matching: .any)["quickrouter.bar.field"]
        let start = app.buttons["quickrouter.bar.start"]
        // After the field, before send, so it reads as part of what is being typed.
        XCTAssertLessThanOrEqual(field.frame.maxX, attach.frame.minX, "the paperclip is at the field's end")
        XCTAssertLessThan(attach.frame.maxX, start.frame.minX, "send stays the trailing control")
        attachScreenshot(app, named: "quick-router-bar-paperclip")

        // With the keyboard up the X joins the row; the empty field's placeholder still fits on
        // one line, so the bar does not grow under the thumb that tapped it.
        let restingHeight = field.frame.height
        field.tap()
        XCTAssertTrue(app.buttons["quickrouter.bar.cancel"].waitForExistence(timeout: timeout))
        XCTAssertEqual(field.frame.height, restingHeight, accuracy: 2, "the focused, empty bar stays one line tall")
        XCTAssertTrue(attach.exists, "the paperclip stays while the bar has the keyboard")
        attachScreenshot(app, named: "quick-router-bar-paperclip-focused")
        app.buttons["quickrouter.bar.cancel"].tap()

        attach.tap()
        XCTAssertTrue(app.buttons["Photo Library"].firstMatch.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["Choose Files"].firstMatch.exists)
        attachScreenshot(app, named: "quick-router-bar-attach-menu")
    }

    func test_a_start_from_the_bar_takes_its_attachment_to_the_session() throws {
        let app = launch(["-ZimmerFixtureQuickRouterAttachment"])
        let chip = app.descendants(matching: .any)["quickrouter.bar.attachment.deploy.log"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout), "the attached file shows above the bar")

        let field = app.descendants(matching: .any)["quickrouter.bar.field"]
        field.tap()
        field.typeText("Why did the deploy fail?")
        attachScreenshot(app, named: "quick-router-bar-attached")
        app.buttons["quickrouter.bar.start"].tap()

        XCTAssertTrue(app.staticTexts["detail.title"].waitForExistence(timeout: timeout))
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "📎 deploy.log")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: timeout), "the started session's first message went with its file")
        attachScreenshot(app, named: "quick-router-bar-attachment-sent")

        app.navigationBars.buttons["Sessions"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        XCTAssertFalse(chip.exists, "the bar is emptied of its attachment by the start")
    }

    func test_an_attachment_can_be_removed_from_the_bar() throws {
        let app = launch(["-ZimmerFixtureQuickRouterAttachment"])
        let chip = app.descendants(matching: .any)["quickrouter.bar.attachment.deploy.log"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))
        app.buttons["quickrouter.bar.attachment.remove.deploy.log"].tap()
        XCTAssertTrue(waitForDisappearance(chip))
    }

    func test_the_sparkles_carry_the_attachment_into_the_sheet_and_back() throws {
        let app = launch(["-ZimmerFixtureQuickRouterAttachment"])
        let barChip = app.descendants(matching: .any)["quickrouter.bar.attachment.deploy.log"]
        XCTAssertTrue(barChip.waitForExistence(timeout: timeout))

        app.buttons["quickrouter.bar.more"].tap()
        let sheetChip = app.descendants(matching: .any)["composer.attachment.deploy.log"]
        XCTAssertTrue(sheetChip.waitForExistence(timeout: timeout), "the sheet opens with the bar's attachment")
        attachScreenshot(app, named: "quick-router-sheet-with-bar-attachment")

        // What the sheet does to them is what the bar gets back: removed there, gone here.
        app.buttons["composer.attachment.remove.deploy.log"].tap()
        XCTAssertTrue(waitForDisappearance(sheetChip))
        app.navigationBars["Quick Router"].buttons["Cancel"].tap()
        XCTAssertTrue(waitForDisappearance(app.navigationBars["Quick Router"]))
        XCTAssertTrue(waitForDisappearance(barChip), "closing the sheet hands the bar the sheet's attachments, not its own")
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
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
