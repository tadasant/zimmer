import XCTest

/// The app, run on a simulator against its `#if DEBUG` fixture (`-ZimmerFixture`): an
/// in-memory Zimmer, because an agent cannot complete a Google sign-in. What this proves is
/// the app's own behaviour — the list orders by urgency, the filters ask for the right
/// rows, the build says which deployment it was made for — not the network.
///
/// One flow, deliberately: a broad, flaky UI suite would redden every iOS pull request.
@MainActor
final class SessionListUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_needs_input_is_the_default_filter_and_sorts_above_everything_else() throws {
        let app = launch()

        // Needs input is selected on launch, and shows exactly the sessions waiting on a person.
        let needsInput = app.descendants(matching: .any)["session.row.1038"]
        XCTAssertTrue(needsInput.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1035"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["session.row.1042"].exists, "running sessions are not in Needs input")
        attachScreenshot(app, named: "sessions-needs-input")

        // Active: everything not archived, in the web UI's phone default, Last Touched — the
        // needs-input session you touched half an hour ago above the running one from earlier.
        app.buttons["filter.active"].tap()
        let running = app.descendants(matching: .any)["session.row.1042"]
        XCTAssertTrue(running.waitForExistence(timeout: timeout))
        let firstNeedsInput = app.descendants(matching: .any)["session.row.1038"]
        XCTAssertTrue(firstNeedsInput.waitForExistence(timeout: timeout))
        XCTAssertLessThan(firstNeedsInput.frame.minY, running.frame.minY, "Last Touched puts the more recently touched session first")
        XCTAssertFalse(app.descendants(matching: .any)["session.row.1019"].exists, "archived is hidden from Active")
        attachScreenshot(app, named: "sessions-active")

        // Archived shows only the archived one.
        app.buttons["filter.archived"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1019"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.descendants(matching: .any)["session.row.1038"].exists)
    }

    func test_the_build_reports_the_environment_and_server_it_was_built_with() throws {
        let app = launch()
        app.buttons["settings.open"].tap()
        let line = app.staticTexts["build.target"]
        XCTAssertTrue(line.waitForExistence(timeout: timeout))
        let fields = Dictionary(uniqueKeysWithValues: line.label.split(separator: " ").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        })
        attachScreenshot(app, named: "settings")
        XCTAssertNotNil(fields["env"], "the build target line did not parse")

        let environment = ProcessInfo.processInfo.environment
        let expectedEnv = environment["ZIMMER_UI_TEST_EXPECT_ENV"] ?? ""
        let expectedHost = environment["ZIMMER_UI_TEST_EXPECT_HOST"] ?? ""
        // `ios/bin/ui-test` asserts the same two values against the built Info.plist, so a
        // run whose runner was not handed them still has evidence.
        if !expectedEnv.isEmpty { XCTAssertEqual(fields["env"], expectedEnv) }
        // The message names neither side: the workflow log is public and masks the host.
        if !expectedHost.isEmpty {
            XCTAssertEqual(fields["host"], expectedHost, "the app reported a different host from the one the build was given")
        }
    }

    func test_the_sign_in_screen_asks_for_a_server_and_offers_sign_in() throws {
        let app = launch(signedOut: true)
        XCTAssertTrue(app.buttons["signin.button"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.textFields["signin.server"].exists)
        attachScreenshot(app, named: "sign-in")
    }

    // MARK: - Helpers

    private func launch(signedOut: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture"] + (signedOut ? ["-ZimmerFixtureSignedOut"] : [])
        app.launch()
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
