import XCTest

/// The deployment switcher, against two in-memory deployments (`-ZimmerFixtureDeployments`):
/// *Workshop*, with the usual sample board, in front, and *Lab*, whose board shares no session
/// with it. Every assertion is on what the board shows after the switch — the other deployment's
/// rows, and none of the first's — so a switch that left any of the old deployment on screen fails.
@MainActor
final class DeploymentSwitcherUITests: XCTestCase {
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    func test_the_switcher_lists_the_deployments_and_a_tap_reloads_the_board_against_the_other() throws {
        let app = launch()
        let workshopRow = app.descendants(matching: .any)["session.row.1038"]
        XCTAssertTrue(workshopRow.waitForExistence(timeout: timeout), "Workshop's board")
        let avatar = app.buttons["deployments.open"]
        XCTAssertTrue(avatar.waitForExistence(timeout: timeout))
        XCTAssertEqual(avatar.label, "Deployment: Workshop")
        attachScreenshot(app, named: "deployments-board-workshop")

        avatar.tap()
        let workshop = app.buttons["deployments.row.workshop"]
        let lab = app.buttons["deployments.row.lab"]
        XCTAssertTrue(workshop.waitForExistence(timeout: timeout))
        XCTAssertTrue(lab.exists)
        XCTAssertEqual(workshop.value as? String, "Current")
        XCTAssertNotEqual(lab.value as? String, "Current")
        XCTAssertTrue(app.buttons["deployments.add"].exists)
        attachScreenshot(app, named: "deployments-switcher")

        lab.tap()
        let labRow = app.descendants(matching: .any)["session.row.4207"]
        XCTAssertTrue(labRow.waitForExistence(timeout: timeout), "Lab's board")
        XCTAssertFalse(app.descendants(matching: .any)["session.row.1038"].exists, "nothing of Workshop's board stays")
        XCTAssertTrue(waitForLabel(app.buttons["deployments.open"], "Deployment: Lab"))
        attachScreenshot(app, named: "deployments-switched-lab")

        // And back: Workshop's board, as it was.
        app.buttons["deployments.open"].tap()
        XCTAssertTrue(app.buttons["deployments.row.lab"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.buttons["deployments.row.lab"].value as? String, "Current")
        app.buttons["deployments.row.workshop"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.descendants(matching: .any)["session.row.4207"].exists)
    }

    func test_adding_a_deployment_signs_in_to_it_and_puts_it_in_front() throws {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].waitForExistence(timeout: timeout))
        app.buttons["deployments.open"].tap()
        let add = app.buttons["deployments.add"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()

        let server = app.textFields["signin.server"]
        XCTAssertTrue(server.waitForExistence(timeout: timeout))
        XCTAssertEqual(app.staticTexts["signin.title"].label, "Add a deployment")
        replaceText(in: server)
        server.typeText("https://third.invalid")
        attachScreenshot(app, named: "deployments-add")
        app.buttons["signin.button"].tap()

        // The fixture's sign-in succeeds at once: the new deployment is in front, on its own board.
        XCTAssertTrue(waitForLabel(app.buttons["deployments.open"], "Deployment: third.invalid"))
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].waitForExistence(timeout: timeout))
        app.buttons["deployments.open"].tap()
        XCTAssertTrue(app.buttons["deployments.row.lab"].waitForExistence(timeout: timeout))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deployments.row.'"))
        XCTAssertEqual(rows.count, 3)
        let added = rows.matching(NSPredicate(format: "value == 'Current'")).firstMatch
        XCTAssertTrue(added.label.contains("third.invalid"), added.label)
        attachScreenshot(app, named: "deployments-added")
    }

    /// A bad address's message does not outlive it: a good address's attempt starts clean, so
    /// closing its sign-in sheet unfinished (`-ZimmerFixtureCancelSignIn`) leaves no error showing.
    func test_a_bad_address_error_clears_when_a_good_address_is_tried_and_its_sign_in_is_closed() throws {
        let app = launch(["-ZimmerFixtureCancelSignIn"])
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].waitForExistence(timeout: timeout))
        app.buttons["deployments.open"].tap()
        XCTAssertTrue(app.buttons["deployments.add"].waitForExistence(timeout: timeout))
        app.buttons["deployments.add"].tap()

        let server = app.textFields["signin.server"]
        XCTAssertTrue(server.waitForExistence(timeout: timeout))
        replaceText(in: server)
        server.typeText("third.invalid")
        app.buttons["signin.button"].tap()
        let banner = app.descendants(matching: .any)["error.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: timeout), "an address with no https:// is refused")
        attachScreenshot(app, named: "deployments-add-bad-address")

        replaceText(in: server)
        server.typeText("https://third.invalid")
        app.buttons["signin.button"].tap()
        XCTAssertTrue(waitForDisappearance(banner), "the bad address's message is gone once a good one is tried")
        XCTAssertTrue(app.buttons["signin.button"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForEnabled(app.buttons["signin.button"]), "the cancelled sign-in has finished")
        XCTAssertFalse(banner.exists, "closing the sign-in sheet is not an error")
        XCTAssertEqual(app.staticTexts["signin.title"].label, "Add a deployment", "the add sheet stays up to try again")
        attachScreenshot(app, named: "deployments-add-sign-in-closed")

        app.buttons["signin.cancel"].tap()
        XCTAssertTrue(waitForDisappearance(app.staticTexts["signin.title"]), "the add sheet closes")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deployments.row.'"))
        XCTAssertTrue(app.buttons["deployments.row.lab"].waitForExistence(timeout: timeout))
        XCTAssertEqual(rows.count, 2, "nothing was added")
    }

    /// A deployment behind Cloudflare Access added with the App host left empty: the web origin's
    /// edge refuses the token call (`-ZimmerFixtureEdgeNeedsAppHost`). The banner says an app host
    /// is likely missing, not "sign in to the edge again", and the collapsed App host row opens,
    /// with the banner still in view: no keyboard comes up over it.
    func test_an_edge_refusal_with_no_app_host_asks_for_one_and_opens_the_app_host_row() throws {
        let app = launch(["-ZimmerFixtureEdgeNeedsAppHost"])
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].waitForExistence(timeout: timeout))
        app.buttons["deployments.open"].tap()
        XCTAssertTrue(app.buttons["deployments.add"].waitForExistence(timeout: timeout))
        app.buttons["deployments.add"].tap()

        let server = app.textFields["signin.server"]
        XCTAssertTrue(server.waitForExistence(timeout: timeout))
        XCTAssertFalse(app.textFields["signin.apphost"].exists, "the App host row starts collapsed")
        replaceText(in: server)
        server.typeText("https://third.invalid")
        app.buttons["signin.button"].tap()

        let banner = app.descendants(matching: .any)["error.edge"]
        XCTAssertTrue(banner.waitForExistence(timeout: timeout))
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "needs an app host")).firstMatch
        XCTAssertTrue(message.exists, "the banner names the missing app host")
        let appHost = app.textFields["signin.apphost"]
        XCTAssertTrue(appHost.waitForExistence(timeout: timeout), "the App host row opens")
        // The keyboard the server field raised goes away on Sign in; wait out its animation.
        XCTAssertTrue(waitForDisappearance(app.keyboards.firstMatch), "no keyboard over the banner")
        attachScreenshot(app, named: "deployments-add-needs-app-host")
        // A label reads whole even when its text is drawn cut to one line, so measure what is drawn.
        XCTAssertGreaterThan(message.frame.height, 90, "the message's five lines are drawn, not cut short")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(message.frame), "the message is on screen")
        XCTAssertGreaterThanOrEqual(message.frame.minY, app.buttons["signin.button"].frame.maxY, "below the button")

        appHost.tap()
        appHost.typeText("https://third-app.invalid")
        app.buttons["signin.button"].tap()
        XCTAssertTrue(waitForLabel(app.buttons["deployments.open"], "Deployment: third.invalid"), "with an app host the sign-in goes through")
    }

    func test_an_address_already_on_the_list_switches_to_it_instead_of_adding_it_again() throws {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].waitForExistence(timeout: timeout))
        app.buttons["deployments.open"].tap()
        XCTAssertTrue(app.buttons["deployments.add"].waitForExistence(timeout: timeout))
        app.buttons["deployments.add"].tap()
        let server = app.textFields["signin.server"]
        XCTAssertTrue(server.waitForExistence(timeout: timeout))
        replaceText(in: server)
        server.typeText("https://lab.invalid/")
        app.buttons["signin.button"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["session.row.4207"].waitForExistence(timeout: timeout))
        app.buttons["deployments.open"].tap()
        XCTAssertTrue(app.buttons["deployments.row.lab"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deployments.row.'")).count, 2)
    }

    func test_signing_out_of_the_one_in_front_brings_the_next_forward_and_leaves_it_signed_in() throws {
        let app = launch(["-ZimmerFixtureLabInFront"])
        XCTAssertTrue(app.descendants(matching: .any)["session.row.4207"].waitForExistence(timeout: timeout))
        app.buttons["deployments.open"].tap()
        let lab = app.buttons["deployments.row.lab"]
        XCTAssertTrue(lab.waitForExistence(timeout: timeout))

        lab.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: timeout))
        delete.tap()
        let confirm = app.buttons["Sign out and remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        confirm.tap()

        XCTAssertTrue(waitForDisappearance(lab))
        let workshop = app.buttons["deployments.row.workshop"]
        XCTAssertTrue(waitForValue(workshop, "Current"), "the one left comes to the front")
        app.buttons["deployments.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.row.1038"].waitForExistence(timeout: timeout),
                      "Workshop is still signed in, on its own board")
        XCTAssertFalse(app.descendants(matching: .any)["session.row.4207"].exists)
    }

    // MARK: - Helpers

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ZimmerFixture", "-ZimmerFixtureDeployments"] + extra
        app.launch()
        return app
    }

    /// Empty the field before typing: whatever an earlier launch left in it is not this test's.
    private func replaceText(in field: XCUIElement) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValue(_ element: XCUIElement, _ value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForEnabled(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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
