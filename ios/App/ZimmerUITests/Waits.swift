import XCTest

/// The waits a UI test uses beside `waitForExistence`. A predicate handed to `XCTWaiter` anywhere
/// else is the flake these are here to end, and `test/config/ios_ui_test_waits_test.rb` fails on a
/// new one.
///
/// A waiter's clock is not a limit on how long the app may take, it is a limit on everything, the
/// looking included. When it runs out XCTest cancels a query that is still being answered, and the
/// wait fails having seen nothing. On main's run 45603621053 the keyboard was gone three seconds
/// before the wait for that began, the one query the wait made was still walking the accessibility
/// tree nineteen seconds later, XCTest logged `Interrupted by waiter`, and the test said the
/// keyboard was up.
///
/// So when the clock runs out each of these looks once more, outside the waiter, where nothing
/// cancels the query. That look begins after the clock ended, so it can only pass on what is on
/// screen then: what is still wrong after the timeout still fails. `waitForExistence` takes the
/// same last look by itself.
extension XCTestCase {
    /// Whether `element` goes away within `timeout`, or has gone by the look taken when it ends.
    @MainActor
    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        completes(NSPredicate(format: "exists == false"), on: element, timeout: timeout) || !element.exists
    }

    /// Whether `predicate` comes true of `element` within `timeout`, or is true of it at the look
    /// taken when that ends. An element that is not there meets no predicate.
    @MainActor
    func waitUntil(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        // Asking an absent element for its label fails the test in XCTest's words, not the caller's.
        completes(predicate, on: element, timeout: timeout) || (element.exists && predicate.evaluate(with: element))
    }

    /// The same of a query, for a predicate on how many elements match it.
    @MainActor
    func waitUntil(_ predicate: NSPredicate, on query: XCUIElementQuery, timeout: TimeInterval = 20) -> Bool {
        completes(predicate, on: query, timeout: timeout) || predicate.evaluate(with: query)
    }

    @MainActor
    func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 20) -> Bool {
        waitUntil(NSPredicate(format: "label == %@", label), on: element, timeout: timeout)
    }

    @MainActor
    func waitForLabelContaining(_ element: XCUIElement, _ text: String, timeout: TimeInterval = 20) -> Bool {
        waitUntil(NSPredicate(format: "label CONTAINS %@", text), on: element, timeout: timeout)
    }

    @MainActor
    func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 20) -> Bool {
        waitUntil(NSPredicate(format: "value == %@", value), on: element, timeout: timeout)
    }

    @MainActor
    private func completes(_ predicate: NSPredicate, on object: Any, timeout: TimeInterval) -> Bool {
        let met = XCTNSPredicateExpectation(predicate: predicate, object: object)
        return XCTWaiter().wait(for: [met], timeout: timeout) == .completed
    }
}
