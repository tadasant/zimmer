import Foundation
import XCTest
@testable import ZimmerKit

/// CarPlay's rules, held on Linux: the modal changes the car makes, what it does when Live Mode
/// will not connect, and what the CarPlay scene's source may and may not contain.
///
/// XCUITest cannot reach the CarPlay window and no CI runner has a head unit, so these are the
/// regression tests for the crashes found in the car (issue #1410). Each fake here fails
/// exactly where CarPlay's documentation says CarPlay does.
@MainActor
final class CarPlayTests: XCTestCase {
    // MARK: - One modal at a time

    /// The interface controller as CarPlay documents it: one modal at a time; a dismissal with
    /// nothing presented fails; and a change that arrives while another is still animating is
    /// refused. A refusal CarPlay is given no completion for is an exception: a crash. Every
    /// refusal is recorded as a `violation`.
    final class StrictHost: CarPlayModalHost {
        final class Template {
            let name: String
            init(_ name: String) { self.name = name }
        }

        struct Refused: Error, CustomStringConvertible {
            let description: String
        }

        /// What is on screen. `presentedTemplate` is what CarPlay hands back for it: with
        /// `proxies` on, a stand-in object rather than the one presented, as CarPlay's is.
        private var onScreen: Template?
        var proxies = false
        var presentedTemplate: Template? {
            guard let onScreen else { return nil }
            return proxies ? Template(onScreen.name + " (proxy)") : onScreen
        }
        /// What is pushed above the root.
        private var stack: [Template] = []
        var pushedCount: Int { stack.count }
        private(set) var violations: [String] = []
        private(set) var history: [String] = []
        private var animating = false
        /// CarPlay refuses the next change for its own reasons (the car is busy).
        var refuseNext = false

        func present(_ template: Template, animated: Bool) async throws {
            try refuseIf(animating, "present \(template.name) during an animation")
            try refuseIf(onScreen != nil, "present \(template.name) over \(onScreen?.name ?? "")")
            try await animate { self.onScreen = template }
            history.append("present \(template.name)")
        }

        func dismissPresented(animated: Bool) async throws {
            try refuseIf(animating, "dismiss during an animation")
            try refuseIf(onScreen == nil, "dismiss with nothing presented")
            let name = onScreen?.name ?? ""
            try await animate { self.onScreen = nil }
            history.append("dismiss \(name)")
        }

        /// A pushed template sits under a modal: CarPlay takes the push and the driver sees
        /// nothing, so a push with a modal up is a violation here.
        func push(_ template: Template, animated: Bool) async throws {
            try refuseIf(animating, "push \(template.name) during an animation")
            try refuseIf(onScreen != nil, "push \(template.name) under \(onScreen?.name ?? "")")
            try await animate { self.stack.append(template) }
            history.append("push \(template.name)")
        }

        func popToRoot(animated: Bool) async throws {
            try refuseIf(animating, "pop during an animation")
            try refuseIf(stack.isEmpty, "pop with nothing pushed")
            try await animate { self.stack.removeAll() }
            history.append("pop")
        }

        /// CarPlay's own Back, which the app is not asked about.
        func driverWentBack() {
            stack.removeAll()
        }

        private func animate(_ change: () -> Void) async throws {
            animating = true
            // An animation takes a few turns of the main loop, so anything else asked for in
            // the meantime arrives mid-animation.
            for _ in 0..<5 { await Task.yield() }
            change()
            animating = false
        }

        private func refuseIf(_ condition: Bool, _ what: String) throws {
            if refuseNext {
                refuseNext = false
                violations.append("refused: \(what)")
                throw Refused(description: what)
            }
            guard condition else { return }
            violations.append(what)
            throw Refused(description: what)
        }
    }

    typealias Template = StrictHost.Template

    /// The fake is strict enough to see the bug: the old scene called the interface controller
    /// directly from changes that did not wait on each other, and two of them inside one
    /// animation are refused.
    func testTheStrictHostRefusesUncoordinatedChangesTheWayCarPlayDoes() async {
        let host = StrictHost()
        let call = Template("call")
        let alert = Template("alert")
        async let first: Void? = try? host.present(call, animated: true)
        async let second: Void? = try? host.present(alert, animated: true)
        _ = await (first, second)
        XCTAssertFalse(host.violations.isEmpty, "two presents inside one animation: CarPlay refuses one, and without a completion that is a crash")

        let empty = StrictHost()
        try? await empty.dismissPresented(animated: true)
        XCTAssertEqual(empty.violations, ["dismiss with nothing presented"])
    }

    /// The storm that crashed the car: the call comes up, fails at once, the car retries, fails
    /// again, and the scene disconnects, none of them waiting on the others.
    func testTheNavigatorMakesEveryChangeInTurnSoCarPlayRefusesNone() async {
        let host = StrictHost()
        let navigator = CarPlayNavigator(host: host)
        var errors: [String] = []
        navigator.onError = { errors.append($0) }
        let call = Template("call")
        let retry = Template("call, retry")
        let again = Template("call, retry again")

        let changes: [@MainActor () async -> Void] = [
            { await navigator.present(call) },
            { await navigator.dismiss(call) },
            { await navigator.present(retry) },
            { await navigator.dismiss(retry) },
            { await navigator.present(again) },
            { await navigator.dismiss(call) },
            { await navigator.dismiss(again) },
            { await navigator.dismiss(again) },
        ]
        await withTaskGroup(of: Void.self) { group in
            for change in changes { group.addTask { await change() } }
        }
        await navigator.settle()

        XCTAssertEqual(host.violations, [])
        XCTAssertEqual(errors, [])
        // The group runs the changes in no fixed order, so what is left on screen varies; that
        // the car can carry on from it does not.
        await navigator.present(call)
        await navigator.dismiss(call)
        XCTAssertNil(host.presentedTemplate)
        XCTAssertEqual(host.violations, [])
    }

    func testPresentingGivesWayToWhateverIsUpAndPresentingTwiceIsOnce() async {
        let host = StrictHost()
        let navigator = CarPlayNavigator(host: host)
        let call = Template("call")
        let other = Template("other")
        await navigator.present(other)
        await navigator.present(call)
        await navigator.present(call)
        XCTAssertTrue(host.presentedTemplate === call)
        XCTAssertEqual(host.history, ["present other", "dismiss other", "present call"])
        XCTAssertEqual(host.violations, [])
    }

    /// The bug the CarPlay drill found in the Simulator's CarPlay window: CarPlay's
    /// `presentedTemplate` is not the object presented, so a navigator that compared by
    /// identity never took the call screen down, and "Connecting…" stayed over a car that had
    /// given up.
    func testTheCallScreenComesDownWhenCarPlayHandsBackAStandInForIt() async {
        let host = StrictHost()
        host.proxies = true
        let navigator = CarPlayNavigator(host: host)
        let call = Template("call")
        await navigator.present(call)
        XCTAssertNotNil(host.presentedTemplate)
        await navigator.present(call)
        XCTAssertEqual(host.history, ["present call"], "presenting the same screen twice is once, stand-in or not")
        await navigator.dismiss(call)
        XCTAssertNil(host.presentedTemplate, "the call screen comes down")

        let retry = Template("call, retry")
        await navigator.present(retry)
        await navigator.dismiss(call)
        XCTAssertNotNil(host.presentedTemplate, "a stale dismissal leaves the retry's screen")
        await navigator.dismiss(retry)
        XCTAssertNil(host.presentedTemplate, "and the retry's comes down too")
        XCTAssertEqual(host.violations, [])
    }

    func testAScreenTheDriverClosedIsNotDismissedAgain() async {
        let host = StrictHost()
        let navigator = CarPlayNavigator(host: host)
        let call = Template("call")
        await navigator.present(call)
        try? await host.dismissPresented(animated: true)
        await navigator.dismiss(call)
        XCTAssertEqual(host.violations, [], "no dismissal with nothing presented")
        let again = await navigator.present(call)
        XCTAssertTrue(again, "and the next call puts it up again")
        XCTAssertEqual(host.history, ["present call", "dismiss call", "present call"])
    }

    func testDismissTakesDownOnlyItsOwnTemplate() async {
        let host = StrictHost()
        let navigator = CarPlayNavigator(host: host)
        let call = Template("call")
        let other = Template("other")
        await navigator.dismiss(call)
        await navigator.present(other)
        await navigator.dismiss(call)
        XCTAssertTrue(host.presentedTemplate === other, "a stale dismissal leaves someone else's modal alone")
        XCTAssertEqual(host.violations, [], "nor does it dismiss with nothing presented")
    }

    func testARefusalIsReportedNotThrown() async {
        let host = StrictHost()
        let navigator = CarPlayNavigator(host: host)
        var errors: [String] = []
        navigator.onError = { errors.append($0) }
        host.refuseNext = true
        let call = Template("call")
        let presented = await navigator.present(call)
        XCTAssertFalse(presented)
        XCTAssertEqual(errors.count, 1, errors.joined())
        XCTAssertTrue(errors[0].contains("present"), errors[0])
        let again = await navigator.present(call)
        XCTAssertTrue(again, "the next change carries on")
    }

    /// The gear: the call screen is a modal and a list cannot be presented, so the panel is
    /// pushed, with the call screen taken down first.
    func testThePanelReplacesTheCallScreenOneChangeAtATime() async {
        let host = StrictHost()
        host.proxies = true
        let navigator = CarPlayNavigator(host: host)
        let call = Template("call")
        let panel = Template("panel")
        await navigator.present(call)

        // Ordered as the scene orders them, none waiting on the one before.
        let down = Task { await navigator.dismiss(call) }
        let up = Task { await navigator.push(panel) }
        await down.value
        let shown = await up.value
        XCTAssertTrue(shown)
        XCTAssertNil(host.presentedTemplate, "nothing is left over the panel")
        XCTAssertEqual(host.pushedCount, 1)

        let again = Template("call again")
        let off = Task { await navigator.pop(panel) }
        let back = Task { await navigator.present(again) }
        await off.value
        _ = await back.value
        await navigator.settle()
        XCTAssertEqual(host.pushedCount, 0)
        XCTAssertNotNil(host.presentedTemplate, "and the call comes back over the root")
        XCTAssertEqual(host.violations, [])
        XCTAssertEqual(host.history, ["present call", "dismiss call", "push panel", "pop", "present call again"])
    }

    func testPushingGivesWayToWhateverModalIsUp() async {
        let host = StrictHost()
        let navigator = CarPlayNavigator(host: host)
        await navigator.present(Template("call"))
        let panel = Template("panel")
        await navigator.push(panel)
        await navigator.push(panel)
        XCTAssertEqual(host.history, ["present call", "dismiss call", "push panel"], "pushing the same panel twice is once")
        XCTAssertEqual(host.violations, [])
    }

    func testThePanelTheDriverLeftWithBackIsNotPoppedAgain() async {
        let host = StrictHost()
        let navigator = CarPlayNavigator(host: host)
        let panel = Template("panel")
        await navigator.push(panel)
        XCTAssertFalse(navigator.isAtRoot)
        host.driverWentBack()
        XCTAssertTrue(navigator.isAtRoot, "this is how the scene hears the driver left")
        await navigator.pop(panel)
        XCTAssertEqual(host.violations, [], "no pop with nothing pushed")
    }

    func testAPopTakesOffOnlyItsOwnTemplate() async {
        let host = StrictHost()
        let navigator = CarPlayNavigator(host: host)
        await navigator.push(Template("panel"))
        await navigator.pop(Template("another"))
        XCTAssertEqual(host.pushedCount, 1)
    }

    func testARefusedPushIsReportedAndTheCarCarriesOn() async {
        let host = StrictHost()
        let navigator = CarPlayNavigator(host: host)
        var errors: [String] = []
        navigator.onError = { errors.append($0) }
        host.refuseNext = true
        let panel = Template("panel")
        let shown = await navigator.push(panel)
        XCTAssertFalse(shown, "the scene brings the call straight back")
        XCTAssertEqual(errors.count, 1, errors.joined())
        await navigator.pop(panel)
        let call = await navigator.present(Template("call"))
        XCTAssertTrue(call)
    }

    func testANavigatorWhoseCarHasGoneDoesNothing() async {
        var host: StrictHost? = StrictHost()
        let navigator = CarPlayNavigator(host: host!)
        host = nil
        let presented = await navigator.present(Template("call"))
        XCTAssertFalse(presented)
        await navigator.dismiss(Template("call"))
    }

    // MARK: - Live Mode unavailable

    func testAFailedCallIsRetriedQuietlyThenTheTileSaysLiveModeIsUnavailable() {
        var retry = LiveRetry()
        XCTAssertEqual(retry.tile(callIsActive: false), .continueConversation)
        retry.asked()
        XCTAssertEqual(retry.failed(), .seconds(2))
        XCTAssertEqual(retry.tile(callIsActive: false), .retrying)
        XCTAssertEqual(retry.tile(callIsActive: false).titleVariants.first, "Live Mode unavailable, retrying…")
        XCTAssertEqual(retry.tile(callIsActive: false), .retrying, "a retry connecting is still retrying, not a choice")
        XCTAssertEqual(retry.failed(), .seconds(5))
        XCTAssertEqual(retry.failed(), .seconds(15))
        XCTAssertNil(retry.failed(), "three retries in a row, then it stops")
        XCTAssertEqual(retry.tile(callIsActive: false), .unavailable)
        XCTAssertNil(retry.failed(), "and stays stopped")

        retry.asked()
        XCTAssertEqual(retry.tile(callIsActive: false), .continueConversation, "a tap is a fresh budget")
        XCTAssertEqual(retry.failed(), .seconds(2))
    }

    func testACallThatComesUpEarnsTheWholeBudgetBackAndAnOffMicrophoneIsNotRetried() {
        var retry = LiveRetry()
        retry.asked()
        _ = retry.failed()
        _ = retry.failed()
        retry.connected()
        XCTAssertEqual(retry.tile(callIsActive: true), .inCall)
        XCTAssertEqual(retry.tile(callIsActive: false), .continueConversation, "a call that came up is not a failure")
        XCTAssertEqual(retry.failed(), .seconds(2), "a drop after a good call starts the budget over")

        var denied = LiveRetry()
        denied.asked()
        denied.gaveUp()
        XCTAssertEqual(denied.tile(callIsActive: false), .unavailable)
        XCTAssertNil(denied.failed())
    }

    func testNothingIsRetriedThatTheDriverDidNotAskForOrHungUp() {
        var retry = LiveRetry()
        XCTAssertNil(retry.failed(), "a call the phone started is the phone's to retry")
        XCTAssertEqual(retry.tile(callIsActive: false), .continueConversation)

        retry.asked()
        _ = retry.failed()
        retry.stopped()
        XCTAssertNil(retry.failed(), "hung up: nothing comes back")
        XCTAssertEqual(retry.tile(callIsActive: false), .continueConversation, "hanging up is not a failure")
    }

    /// Two calls that each hang to the deadline, then falling notes: about half a minute from
    /// the tap, where three retries of hanging calls would have taken over a minute.
    func testHangingCallsSpendTheBudgetInTimeNotTries() {
        var retry = LiveRetry()
        retry.asked(at: 100)
        XCTAssertEqual(retry.failed(at: 115), .seconds(2), "the first hang gets a retry")
        XCTAssertNil(retry.failed(at: 132), "the second is too late for another wait")
        XCTAssertEqual(retry.tile(callIsActive: false), .unavailable)
        XCTAssertFalse(retry.wanted)

        var quick = LiveRetry()
        quick.asked(at: 100)
        XCTAssertEqual(quick.failed(at: 100.5), .seconds(2))
        XCTAssertEqual(quick.failed(at: 103), .seconds(5))
        XCTAssertEqual(quick.failed(at: 108.5), .seconds(15), "calls that fail at once still get all three")

        var dropped = LiveRetry()
        dropped.asked(at: 0)
        dropped.connected()
        XCTAssertEqual(dropped.failed(at: 900), .seconds(2), "a good call that drops gets a budget from the drop")
        XCTAssertEqual(dropped.failed(at: 917), .seconds(5))
        XCTAssertNil(dropped.failed(at: 934), "and it runs out the same way")
    }

    func testATapShowsAtOnceAndASecondTapIsNotASecondAttempt() {
        var retry = LiveRetry()
        retry.asked()
        retry.lookup()
        XCTAssertEqual(retry.tile(callIsActive: false), .connecting, "the car answers the tap before the call exists")
        XCTAssertTrue(retry.lookingUp)
        retry.lookedUp()
        XCTAssertEqual(retry.tile(callIsActive: true), .inCall)
        XCTAssertEqual(retry.failed(), .seconds(2))
        retry.lookup()
        XCTAssertEqual(retry.tile(callIsActive: false), .retrying, "a retry looking up is still retrying")
    }

    func testEveryTileSaysSomethingOnANarrowScreen() {
        for tile in [LiveTalkTile.continueConversation, .newConversation, .connecting, .inCall, .retrying, .unavailable] {
            XCTAssertEqual(tile.titleVariants.count, 2)
            XCTAssertLessThanOrEqual(tile.titleVariants[1].count, 10, "\(tile)")
            XCTAssertFalse(tile.symbol.isEmpty)
        }
    }

    // MARK: - Continue or New

    func testAtRestTheDriverChoosesAndWithNothingOpenThereIsOnlyNew() {
        let retry = LiveRetry()
        XCTAssertEqual(retry.tiles(callIsActive: false, conversationOpen: true), [.continueConversation, .newConversation])
        XCTAssertEqual(retry.tiles(callIsActive: false, conversationOpen: nil), [.continueConversation, .newConversation],
                       "before Zimmer has said, both: one is nearly always open, and the tap reads again")
        XCTAssertEqual(retry.tiles(callIsActive: false, conversationOpen: false), [.newConversation], "no tile that does nothing")
    }

    /// Whatever is open, a tile under way is one tile: there is nothing to choose.
    func testAnythingUnderWayIsOneTile() {
        for open in [true, false, nil] as [Bool?] {
            var retry = LiveRetry()
            XCTAssertEqual(retry.tiles(callIsActive: true, conversationOpen: open), [.inCall])
            retry.asked()
            retry.lookup()
            XCTAssertEqual(retry.tiles(callIsActive: false, conversationOpen: open), [.connecting])
            retry.lookedUp()
            XCTAssertNotNil(retry.failed())
            XCTAssertEqual(retry.tiles(callIsActive: false, conversationOpen: open), [.retrying])
        }
    }

    /// A conversation that will not connect is when New is most wanted.
    func testGivingUpKeepsNewBesideRetry() {
        var retry = LiveRetry()
        retry.asked()
        retry.gaveUp()
        for open in [true, false, nil] as [Bool?] {
            XCTAssertEqual(retry.tiles(callIsActive: false, conversationOpen: open), [.unavailable, .newConversation])
        }
    }

    func testEachTileMakesItsChoiceAndAStatusTileAsksAgain() {
        var wish = CarLiveWish()
        XCTAssertEqual(wish.choice, .continueOpen)
        wish.tapped(.newConversation, callIsActive: false)
        XCTAssertEqual(wish.choice, .startNew)
        for status in [LiveTalkTile.connecting, .retrying, .unavailable] {
            wish.tapped(status, callIsActive: false)
            XCTAssertEqual(wish.choice, .startNew, "\(status) repeats the wish: a failed New retries New, not the old conversation")
        }
        wish.tapped(.continueConversation, callIsActive: false)
        XCTAssertEqual(wish.choice, .continueOpen)
    }

    func testAStaleNewTileGoesBackToARunningCallRatherThanReplacingIt() {
        var wish = CarLiveWish()
        wish.tapped(.newConversation, callIsActive: true)
        XCTAssertEqual(wish.choice, .continueOpen)
    }

    func testContinueCallsTheOpenConversationAndStartsNothing() async throws {
        let api = FakeZimmerAPI()
        let wish = CarLiveWish()
        let before = try await api.liveConversations().conversations.count
        let id = try await api.conversation(for: wish.choice)
        XCTAssertEqual(id, 21)
        let after = try await api.liveConversations()
        XCTAssertEqual(after.conversations.count, before)
        XCTAssertEqual(after.current, 21)
    }

    func testNewEndsTheOpenConversationAndTheOldOneStaysReadable() async throws {
        let api = FakeZimmerAPI()
        var wish = CarLiveWish()
        wish.tapped(.newConversation, callIsActive: false)
        let answer = try await api.conversation(for: wish.choice)
        let id = try XCTUnwrap(answer)
        XCTAssertNotEqual(id, 21)
        let current = try await api.liveConversations().current
        XCTAssertEqual(current, id)
        let new = try await api.liveConversation(id, afterTurn: nil)
        XCTAssertEqual(new.mode, .voice, "the car's call has voice on")
        let old = try await api.liveConversation(21, afterTurn: nil)
        XCTAssertFalse(old.status.isOpen)
        XCTAssertEqual(old.turns?.isEmpty, false, "and what was said in it is still there")
    }

    /// The bug a naive New would have: every retry a fresh conversation, ending the last one.
    func testARetryAfterNewCallsTheConversationNewStartedRatherThanAnother() async throws {
        let api = FakeZimmerAPI()
        var wish = CarLiveWish()
        wish.tapped(.newConversation, callIsActive: false)
        let first = try await api.conversation(for: wish.choice)
        XCTAssertNotNil(first)
        wish.answered()
        let total = try await api.liveConversations().conversations.count
        for _ in 0..<3 {
            let again = try await api.conversation(for: wish.choice)
            XCTAssertEqual(again, first)
        }
        let after = try await api.liveConversations().conversations.count
        XCTAssertEqual(after, total, "no second conversation")
    }

    /// A start Zimmer never answered made no conversation the car knows of, so Retry starts one.
    func testAStartNeverAnsweredIsStillNew() {
        var wish = CarLiveWish()
        wish.tapped(.newConversation, callIsActive: false)
        wish.tapped(.unavailable, callIsActive: false)
        XCTAssertEqual(wish.choice, .startNew)
    }

    func testContinueWithNothingOpenFindsNothingAndStartsNothing() async throws {
        let api = FakeZimmerAPI()
        _ = try await api.finishLiveConversation(21)
        let wish = CarLiveWish()
        let id = try await api.conversation(for: wish.choice)
        XCTAssertNil(id, "the car does not swap in a new thread for the one the driver asked to continue")
        let current = try await api.liveConversations().current
        XCTAssertNil(current)
    }

    /// The tap before any `await`: a tap arriving during one must find the attempt under way, or
    /// New reaches Zimmer twice.
    func testASecondTapIsHeldOffBeforeAnythingAsynchronousRuns() async throws {
        let live = Self.carPlaySources.first { $0.name == "CarPlayLive.swift" }?.text ?? ""
        let start = try XCTUnwrap(live.range(of: "private func attempt() {"))
        let body = live[start.upperBound...]
        let lookup = try XCTUnwrap(body.range(of: "retry.lookup()"))
        let task = try XCTUnwrap(body.range(of: "Task {"))
        XCTAssertLessThan(lookup.lowerBound, task.lowerBound, "attempt() marks the lookup before its Task")
    }

    /// A muted driver who chooses a fresh start asked to talk. Retry keeps the mute, in
    /// `CarCallComeback`; New lets go of the comeback that holds it.
    func testNewLetsGoOfTheMuteTheComebackHeld() async throws {
        let live = Self.carPlaySources.first { $0.name == "CarPlayLive.swift" }?.text ?? ""
        XCTAssertTrue(live.contains("if wish.choice == .startNew { comeback = nil }"))
    }

    // MARK: - The scene's source

    private static var carPlaySources: [(name: String, text: String)] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let folder = tests.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Zimmer/CarPlay")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
            (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
        }
    }

    private static var appSources: [(name: String, text: String)] {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let app = tests.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Zimmer")
        guard let walker = FileManager.default.enumerator(atPath: app.path) else { return [] }
        return walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
            (try? String(contentsOf: app.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
        }
    }

    /// Talk is heard at once. The car's tap plays *pressed* before it asks Zimmer which
    /// conversation to call, and a call nobody pressed for plays it before it turns voice on or
    /// mints its secret, so the cue never waits on the network. It plays on an engine that never
    /// opens the microphone: CarPlay records only under the voice control template, which is not
    /// up yet at the tap.
    func testThePressIsHeardBeforeAnyNetworkStepAndOpensNoMicrophone() throws {
        func body(_ file: String, from start: String) throws -> String {
            let text = try XCTUnwrap(Self.appSources.first { $0.name.hasSuffix(file) }?.text, file)
            let source = Self.code(text).map(\.line).joined(separator: "\n")
            let open = try XCTUnwrap(source.range(of: start), start)
            return String(source[open.lowerBound...])
        }
        let tap = try body("CarPlay/CarPlayLive.swift", from: "func start(_ tile: LiveTalkTile)")
        let pressed = try XCTUnwrap(tap.range(of: "call.pressed()"), "the tap plays the cue")
        let attempt = try XCTUnwrap(tap.range(of: "attempt()"))
        XCTAssertLessThan(pressed.lowerBound, attempt.lowerBound, "before the conversation is looked up")

        let call = try body("Live/LiveCall.swift", from: "func start(_ conversation: Int")
        let own = try XCTUnwrap(call.range(of: "pressed()"))
        for network in ["turnVoiceOn(", "mintSecret(", "openSocket(", "audio.start("] {
            let step = try XCTUnwrap(call.range(of: network), network)
            XCTAssertLessThan(own.lowerBound, step.lowerBound, "*pressed* before \(network)")
        }

        let press = try body("Live/LiveCall.swift", from: "func pressed()")
        let end = try XCTUnwrap(press.range(of: "\n    }\n"))
        let pressBody = String(press[..<end.upperBound])
        XCTAssertTrue(pressBody.contains("audio.playAlone(.pressed"), "on the engine that has no input")
        XCTAssertFalse(pressBody.contains("audio.start("), "never the call's engine, which opens the microphone")
        let alone = try body("Live/LiveAudioEngine.swift", from: "func playAlone(")
        let aloneEnd = try XCTUnwrap(alone.range(of: "\n    }\n"))
        let aloneBody = String(alone[..<aloneEnd.upperBound])
        for input in ["inputNode", "requestRecordPermission", "installTap"] {
            XCTAssertFalse(aloneBody.contains(input), "playAlone touches no input: \(input)")
        }
    }

    /// `bda7cf2e` sat 770 s inside the engine's start with the main thread waiting on it, so no
    /// deadline could fire, End could not be pressed and the screen could not change. The calls
    /// that can block run on the audio queue; this is what keeps them there.
    func testTheCallsThatCanBlockNeverRunOnTheMainActor() async throws {
        let text = try XCTUnwrap(Self.appSources.first { $0.name.hasSuffix("Live/LiveAudioEngine.swift") }?.text)
        let source = Self.code(text).map(\.line).joined(separator: "\n")
        let graph = try XCTUnwrap(source.range(of: "private struct Graph"))
        let telemetry = try XCTUnwrap(source.range(of: "private nonisolated static let telemetry"))
        let mainActor = String(source[source.startIndex..<graph.lowerBound]) + String(source[telemetry.upperBound...])
        var outsideGraph = mainActor
        for closure in ["try await Self.onQueue {", "Self.queue.async {", "func activateSession"] {
            XCTAssertTrue(mainActor.contains(closure), closure)
        }
        // Everything inside a closure handed to the queue is what the queue runs.
        while let open = outsideGraph.range(of: "Self.onQueue {") ?? outsideGraph.range(of: "Self.queue.async {") {
            var depth = 1
            var index = open.upperBound
            while depth > 0, index < outsideGraph.endIndex {
                if outsideGraph[index] == "{" { depth += 1 }
                if outsideGraph[index] == "}" { depth -= 1 }
                index = outsideGraph.index(after: index)
            }
            outsideGraph.removeSubrange(open.lowerBound..<index)
        }
        let activate = try XCTUnwrap(outsideGraph.range(of: "private nonisolated static func activateSession"))
        let afterActivate = try XCTUnwrap(outsideGraph.range(of: "private let sink = FrameSink()", range: activate.upperBound..<outsideGraph.endIndex))
        outsideGraph.removeSubrange(activate.lowerBound..<afterActivate.lowerBound)
        for blocking in ["engine.start()", "engine?.start()", "setActive(", "setVoiceProcessingEnabled", ".configure(sink:", "engine.stop()", "tearDown(deactivate"] {
            XCTAssertFalse(outsideGraph.contains(blocking), "\(blocking) on the main actor")
        }
    }

    /// An engine handed between the main actor and the audio queue is every node of it, each way:
    /// one left behind means `stop()` cannot tear the engine down.
    func testEveryNodeOfAnEngineIsHandedBack() async throws {
        let source = try XCTUnwrap(Self.appSources.first { $0.name.hasSuffix("Live/LiveAudioEngine.swift") }?.text)
        let nodes = ["engine", "player", "cuePlayer", "loopPlayer"]
        for node in nodes {
            XCTAssertEqual(source.components(separatedBy: "self.\(node) = graph.\(node)").count - 1, 1, "\(node), after a restart")
            XCTAssertEqual(source.components(separatedBy: "        \(node) = graph.\(node)\n").count - 1, 1, "\(node), after a start")
            XCTAssertEqual(source.components(separatedBy: "self.\(node) = nil").count - 1, 1, "\(node), handed over for a restart")
        }
        for property in ["bringingUp", "resets", "awaitingPermission"] {
            XCTAssertTrue(source.contains("var \(property) "), "\(property) is declared")
        }
    }

    /// Lines of code, comments dropped, so a comment that names a rule is not read as breaking it.
    private static func code(_ text: String) -> [(number: Int, line: String)] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") ? nil : (index + 1, line)
        }
    }

    func testTheSceneSourcesAreThere() {
        XCTAssertGreaterThanOrEqual(Self.carPlaySources.count, 3, "the guards below would pass on an empty folder")
        XCTAssertTrue(Self.carPlaySources.contains { $0.name == "CarPlaySceneDelegate.swift" })
    }

    /// CarPlay throws an exception — the app crashes — when a present, dismiss, push, pop or
    /// root change fails and was given no completion. The async form always gives one, so the
    /// scene calls the interface controller only that way, and only from `CarPlayInterface`.
    func testTheSceneNeverCallsTheInterfaceControllerWithoutACompletion() {
        let calls = ["presentTemplate(", "dismissTemplate(", "pushTemplate(", "popTemplate(", "popToRootTemplate(", "pop(to:", "setRootTemplate("]
        for (name, text) in Self.carPlaySources {
            for (number, line) in Self.code(text) {
                XCTAssertFalse(line.contains("completion:"), "\(name):\(number): a CarPlay call with a completion argument; use the async form through CarPlayNavigator\n\(line)")
                guard calls.contains(where: line.contains) else { continue }
                XCTAssertEqual(name, "CarPlayInterface.swift", "\(name):\(number): the interface controller is called only from CarPlayInterface\n\(line)")
                XCTAssertTrue(line.contains("try await"), "\(name):\(number): only the async form, which CarPlay always answers through a completion\n\(line)")
            }
        }
    }

    /// The car has one voice, the Realtime call. Nothing in the app speaks with the system's.
    func testNothingInTheAppSpeaksWithTheSystemVoice() {
        for (name, text) in Self.appSources {
            for (number, line) in Self.code(text) {
                for voice in ["AVSpeechSynthesizer", "AVSpeechUtterance", "SFSpeechRecognizer"] {
                    XCTAssertFalse(line.contains(voice), "\(name):\(number): \(voice) — the only voice is Live Mode's\n\(line)")
                }
            }
        }
    }

    /// One thread: the car talks to sessions only through the Live Mode conversation. No
    /// follow-up, merge, restart or archive straight to a session from a tap.
    func testTheCarReachesSessionsOnlyThroughLiveMode() {
        let direct = ["followUp(", "authorizeMerge(", ".restart(", ".archive(", ".trash(", "sendMessage("]
        for (name, text) in Self.carPlaySources {
            for (number, line) in Self.code(text) {
                for call in direct {
                    XCTAssertFalse(line.contains(call), "\(name):\(number): \(call) goes around Live Mode\n\(line)")
                }
            }
        }
    }

    /// The call screen is built from `LiveCallScreen.identifiers` and nothing else: CarPlay keeps five.
    func testTheCallScreenIsBuiltFromTheFiveStates() {
        let live = Self.carPlaySources.first { $0.name == "CarPlayLive.swift" }?.text ?? ""
        XCTAssertTrue(live.contains("LiveCallScreen.identifiers"), "CarPlayLive builds its states from LiveCallScreen.identifiers")
        XCTAssertFalse(live.contains("for muted in"), "a muted twin of every state is ten states; CarPlay keeps five")
    }

    /// Radically simple: the car is a home of tiles, one call screen and one panel behind the call
    /// screen's gear. A tab bar, a card, an alert, an action sheet or any other list is one more
    /// template CarPlay can refuse a change to, and the car had all of them when it crashed. The
    /// panel is the one exception, made on purpose: a call that cannot hear the driver cannot be
    /// asked to fix that (`ios/CARPLAY_DESIGN.md`).
    func testTheCarIsAHomeOneCallScreenAndOnePanel() {
        let allowed: Set = ["CPTemplate", "CPGridTemplate", "CPVoiceControlTemplate", "CPListTemplate"]
        let template = try! NSRegularExpression(pattern: #"\bCP[A-Za-z]*Template\b"#)
        var seen: Set<String> = []
        for (name, text) in Self.carPlaySources {
            for (number, line) in Self.code(text) {
                for match in template.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range, in: line) else { continue }
                    let used = String(line[range])
                    seen.insert(used)
                    XCTAssertTrue(allowed.contains(used), "\(name):\(number): \(used) — the car is a home of tiles (CPGridTemplate), the call screen (CPVoiceControlTemplate) and the voice settings (CPListTemplate)\n\(line)")
                    if used == "CPListTemplate" {
                        XCTAssertEqual(name, "CarPlayVoiceSettings.swift", "\(name):\(number): the one list in the car is the voice settings\n\(line)")
                    }
                }
                if line.contains("navigator.push(") || line.contains("pushTemplate") {
                    XCTAssertTrue(line.contains("panel.template") || name == "CarPlayInterface.swift", "\(name):\(number): the only thing pushed in the car is the voice settings\n\(line)")
                }
            }
        }
        XCTAssertTrue(seen.isSuperset(of: ["CPGridTemplate", "CPVoiceControlTemplate", "CPListTemplate"]), "the guard sees the three templates the car does use: \(seen)")
    }

    /// The microphone is open only with the voice control template on screen, so the call ends
    /// before its screen goes and before the panel goes up.
    func testTheGearEndsTheCallBeforeThePanelGoesUp() async throws {
        let live = Self.carPlaySources.first { $0.name == "CarPlayLive.swift" }?.text ?? ""
        let gear = try XCTUnwrap(live.range(of: "private func openSettings()"))
        let body = live[gear.upperBound...]
        let hangUp = try XCTUnwrap(body.range(of: "call.hangUp()"))
        let down = try XCTUnwrap(body.range(of: "dismiss()"))
        let up = try XCTUnwrap(body.range(of: "navigator.push(panel.template)"))
        XCTAssertLessThan(hangUp.lowerBound, down.lowerBound)
        XCTAssertLessThan(down.lowerBound, up.lowerBound)
    }

    /// A tap that CarPlay delivers off the main thread still reaches the main actor. A closure
    /// written in a `@MainActor` type and handed to CarPlay would trap on its first instruction,
    /// the likeliest reason the gear ended the app with nothing logged (`CarPlayTap`).
    func testATapFromAnyThreadRunsOnTheMainActorAndSaysItWasOff() async {
        let arrivedOnMain = Recorded()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let tapped: (String) -> Void = CarPlayTap.handler(arrived: { arrivedOnMain.set($0) }) {
                MainActor.preconditionIsolated()
                done.resume()
            }
            nonisolated(unsafe) let press = tapped
            Thread.detachNewThread { press("gear") }
        }
        XCTAssertEqual(arrivedOnMain.value, false)
    }

    func testATapOnTheMainThreadRunsAndSaysItWasOnIt() async {
        let arrivedOnMain = Recorded()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CarPlayTap.run(arrived: { arrivedOnMain.set($0) }) { done.resume() }
        }
        XCTAssertEqual(arrivedOnMain.value, true)
    }

    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        func set(_ value: Bool) { lock.withLock { stored = value } }
        var value: Bool? { lock.withLock { stored } }
    }

    /// Every control on the home, the call screen and the panel hands CarPlay a closure that belongs to no
    /// actor. One written in `CarPlayLive`, or in a `CarPlayVoiceSettings` method that is not
    /// nonisolated, inherits the main actor, and `MainActor.assumeIsolated` traps the same way.
    func testTheHomeTheCallScreenAndThePanelGiveCarPlayNoIsolatedHandler() {
        func code(_ name: String) -> [String] {
            Self.code(Self.carPlaySources.first { $0.name == name }?.text ?? "").map(\.line)
        }
        let live = code("CarPlayLive.swift")
        for line in live where line.contains("{ [weak self] _ in") {
            XCTAssertTrue(line.contains(".sink"), "CarPlayLive: a handler closure written in place inherits the main actor\n\(line)")
        }
        for control in ["gear", "mute", "end", "send_now"] {
            XCTAssertTrue(live.contains { $0.contains("CarPlayImages.tapped(\"\(control)\")") }, "\(control) goes through CarPlayTap")
        }
        let home = code("CarPlayHome.swift")
        XCTAssertTrue(home.contains { $0.contains("handler: CarPlayImages.tapped(") }, "the tiles go through CarPlayTap")
        for line in home {
            XCTAssertFalse(line.contains("{ [weak self] _ in"), "CarPlayHome: a handler closure written in place inherits the main actor\n\(line)")
        }
        let panel = code("CarPlayVoiceSettings.swift")
        XCTAssertTrue(panel.contains { $0.contains("nonisolated static func handler(") }, "a row's closure is built where no actor is inherited")
        for line in panel {
            XCTAssertFalse(line.contains("MainActor.assumeIsolated"), "assumeIsolated traps off the main thread\n\(line)")
            XCTAssertFalse(line.contains(".handler = {"), "a row's closure written in place inherits the main actor\n\(line)")
        }
        XCTAssertTrue(code("CarPlaySceneDelegate.swift").contains { $0.contains("nonisolated func templateDidAppear") }, "CarPlay's delegate call hops to the main actor itself")
    }

    /// The gear is the template's, set once, so the five states stay what they are.
    func testTheGearIsOnTheCallScreenFromTheDayItIsBuilt() {
        let live = Self.carPlaySources.first { $0.name == "CarPlayLive.swift" }?.text ?? ""
        XCTAssertTrue(live.contains("screen.leadingNavigationBarButtons"), "the gear is the call screen's leading bar button")
        XCTAssertEqual(live.components(separatedBy: "NavigationBarButtons =").count - 1, 1, "and it is the only time a bar button is set")
    }

    /// `@Published` publishes in `willSet`: a sink that reads the call synchronously reads the
    /// state it is leaving, which put the call screen up only once the microphone was already
    /// open, and activated the previous state's picture. Every sink on the call is received on
    /// the main queue's next turn.
    func testEverySinkOnTheCallReadsTheCallAfterItChanged() {
        for (name, text) in Self.carPlaySources {
            for (number, line) in Self.code(text) where line.contains("call.$") {
                XCTAssertTrue(line.contains(".receive(on: DispatchQueue.main)"), "\(name):\(number): a sink on LiveCall that runs before the value is stored\n\(line)")
            }
        }
    }
}
