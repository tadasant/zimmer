import XCTest

/// Photos and files on a follow-up, against the `-ZimmerFixture` in-memory Zimmer. The
/// system pickers cannot be driven from a UI test, so `-ZimmerFixtureAttachment` starts the
/// composer with a file attached; the paperclip's two choices are checked on their own.
@MainActor
final class AttachmentsUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_a_message_goes_with_its_attachment() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1035", "-ZimmerFixtureAttachment"])
        let chip = app.descendants(matching: .any)["composer.attachment.deploy.log"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))

        let field = app.descendants(matching: .any)["followup.field"]
        field.tap()
        field.typeText("Why did this fail?")
        app.buttons["followup.send"].tap()

        XCTAssertTrue(waitForDisappearance(chip), "the composer is cleared once the message is sent")
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "📎 deploy.log")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: timeout), "the conversation shows the message went with its file")
    }

    func test_an_attachment_can_be_removed_before_sending() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1035", "-ZimmerFixtureAttachment"])
        let chip = app.descendants(matching: .any)["composer.attachment.deploy.log"]
        XCTAssertTrue(chip.waitForExistence(timeout: timeout))
        app.buttons["Remove deploy.log"].tap()
        XCTAssertTrue(waitForDisappearance(chip))
    }

    func test_the_paperclip_offers_photos_and_files() throws {
        let app = launch(["-ZimmerFixtureOpenSession", "1035"])
        let attach = app.buttons["composer.attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: timeout))
        attach.tap()
        XCTAssertTrue(app.buttons["Photo Library"].firstMatch.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["Choose Files"].firstMatch.exists)
    }

    // MARK: - Helpers

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + extra
        app.launch()
        return app
    }

    private func waitForDisappearance(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
