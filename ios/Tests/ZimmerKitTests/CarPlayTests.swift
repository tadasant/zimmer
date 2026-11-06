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
        XCTAssertEqual(retry.tile(callIsActive: false), .ready)
        retry.asked()
        XCTAssertEqual(retry.failed(), .seconds(2))
        XCTAssertEqual(retry.tile(callIsActive: false), .retrying)
        XCTAssertEqual(retry.tile(callIsActive: false).titleVariants.first, "Live Mode unavailable, retrying…")
        XCTAssertEqual(retry.tile(callIsActive: false), .retrying, "a retry connecting is still retrying, not Talk to Zimmer")
        XCTAssertEqual(retry.failed(), .seconds(5))
        XCTAssertEqual(retry.failed(), .seconds(15))
        XCTAssertNil(retry.failed(), "three retries in a row, then it stops")
        XCTAssertEqual(retry.tile(callIsActive: false), .unavailable)
        XCTAssertNil(retry.failed(), "and stays stopped")

        retry.asked()
        XCTAssertEqual(retry.tile(callIsActive: false), .ready, "a tap is a fresh budget")
        XCTAssertEqual(retry.failed(), .seconds(2))
    }

    func testACallThatComesUpEarnsTheWholeBudgetBackAndAnOffMicrophoneIsNotRetried() {
        var retry = LiveRetry()
        retry.asked()
        _ = retry.failed()
        _ = retry.failed()
        retry.connected()
        XCTAssertEqual(retry.tile(callIsActive: true), .inCall)
        XCTAssertEqual(retry.tile(callIsActive: false), .ready, "a call that came up is not a failure")
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
        XCTAssertEqual(retry.tile(callIsActive: false), .ready)

        retry.asked()
        _ = retry.failed()
        retry.stopped()
        XCTAssertNil(retry.failed(), "hung up: nothing comes back")
        XCTAssertEqual(retry.tile(callIsActive: false), .ready, "hanging up is not a failure")
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
        for tile in [LiveTalkTile.ready, .connecting, .inCall, .retrying, .unavailable] {
            XCTAssertEqual(tile.titleVariants.count, 2)
            XCTAssertLessThanOrEqual(tile.titleVariants[1].count, 10, "\(tile)")
            XCTAssertFalse(tile.symbol.isEmpty)
        }
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

    /// Radically simple: the car is one button, one call screen and one panel behind the call
    /// screen's gear. A tab bar, a card, an alert, an action sheet or any other list is one more
    /// template CarPlay can refuse a change to, and the car had all of them when it crashed. The
    /// panel is the one exception, made on purpose: a call that cannot hear the driver cannot be
    /// asked to fix that (`ios/CARPLAY_DESIGN.md`).
    func testTheCarIsOneButtonOneCallScreenAndOnePanel() {
        let allowed: Set = ["CPTemplate", "CPGridTemplate", "CPVoiceControlTemplate", "CPListTemplate"]
        let template = try! NSRegularExpression(pattern: #"\bCP[A-Za-z]*Template\b"#)
        var seen: Set<String> = []
        for (name, text) in Self.carPlaySources {
            for (number, line) in Self.code(text) {
                for match in template.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range, in: line) else { continue }
                    let used = String(line[range])
                    seen.insert(used)
                    XCTAssertTrue(allowed.contains(used), "\(name):\(number): \(used) — the car is a Talk button (CPGridTemplate), the call screen (CPVoiceControlTemplate) and the voice settings (CPListTemplate)\n\(line)")
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
        let offMain = Flag()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let tapped: (String) -> Void = CarPlayTap.handler(offMain: { offMain.set() }) {
                MainActor.preconditionIsolated()
                done.resume()
            }
            nonisolated(unsafe) let press = tapped
            Thread.detachNewThread { press("gear") }
        }
        XCTAssertTrue(offMain.isSet)
    }

    func testATapOnTheMainThreadStillRunsAndSaysNothing() async {
        let offMain = Flag()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            CarPlayTap.run(offMain: { offMain.set() }) { done.resume() }
        }
        XCTAssertFalse(offMain.isSet)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// Every control on the call screen and the panel hands CarPlay a closure that belongs to no
    /// actor. A closure in place in `CarPlayLive` or `CarPlayVoiceSettings` would inherit the main
    /// actor and trap off the main thread, and `MainActor.assumeIsolated` would do the same.
    func testTheCallScreenAndThePanelGiveCarPlayNoIsolatedHandler() {
        for name in ["CarPlayLive.swift", "CarPlayVoiceSettings.swift", "CarPlaySceneDelegate.swift"] {
            let text = Self.carPlaySources.first { $0.name == name }?.text ?? ""
            XCTAssertFalse(text.isEmpty, name)
            for (number, line) in Self.code(text) {
                XCTAssertFalse(line.contains("CPBarButton(image:") && line.contains("{"), "\(name):\(number): a bar button's closure in place inherits the main actor\n\(line)")
                XCTAssertFalse(line.contains("actionButton(") && !line.contains("CarPlayImages.tapped("), "\(name):\(number): a button's closure in place inherits the main actor\n\(line)")
                XCTAssertFalse(line.contains(".handler = {"), "\(name):\(number): a row's closure in place inherits the main actor\n\(line)")
                if name == "CarPlayVoiceSettings.swift" {
                    XCTAssertFalse(line.contains("MainActor.assumeIsolated"), "\(name):\(number): assumeIsolated traps off the main thread\n\(line)")
                }
            }
        }
        let delegate = Self.carPlaySources.first { $0.name == "CarPlaySceneDelegate.swift" }?.text ?? ""
        XCTAssertTrue(delegate.contains("nonisolated func templateDidAppear"), "CarPlay's delegate call hops to the main actor itself")
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
