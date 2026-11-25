import XCTest
@testable import ZimmerKit

/// Standby's rules (`LiveWarmStart`): when a connection is made ready, kept, replaced and dropped,
/// what a tap gets, what it is allowed to cost, and the rule the whole feature stands on — nothing
/// goes up a connection in standby before the person taps.
final class LiveWarmStartTests: XCTestCase {
    private let ready = LiveWarmStart.Conditions(conversation: 7)

    /// Connected, refreshed with `conditions`, and (unless `warm` is false) warm at `at`.
    private func started(_ conditions: LiveWarmStart.Conditions? = nil, at: TimeInterval = 0, warm: Bool = true) -> LiveWarmStart {
        var start = LiveWarmStart()
        XCTAssertEqual(start.activate(at: at), [.refresh])
        _ = start.update(conditions ?? ready, at: at)
        if warm { start.ready(at: at + 1) }
        return start
    }

    /// Ticks from `from` to `to`, a second apart, answering every ping with a pong.
    @discardableResult
    private func run(_ start: inout LiveWarmStart, from: TimeInterval, to: TimeInterval, pongs: Bool = true) -> [(TimeInterval, LiveWarmStart.Action)] {
        var actions: [(TimeInterval, LiveWarmStart.Action)] = []
        var now = from
        while now <= to {
            for action in start.tick(at: now) {
                actions.append((now, action))
                if pongs, action == .ping { start.heard(at: now + 0.1) }
            }
            now += 1
        }
        return actions
    }

    // MARK: - Warming

    func testTheCarConnectingReadsWhatIsOpenAndWarmsTheOpenConversation() {
        var start = LiveWarmStart()
        XCTAssertEqual(start.activate(at: 0), [.refresh])
        XCTAssertEqual(start.update(ready, at: 0.3), [.mint(conversation: 7)])
        XCTAssertEqual(start.phase, .warming)
        start.ready(at: 1.2)
        XCTAssertEqual(start.phase, .warm)
        XCTAssertEqual(start.conversation, 7)
        XCTAssertEqual(start.update(ready, at: 2), [], "a refresh that changes nothing changes nothing")
    }

    func testTheOpenConversationIsReadAgainEveryRefresh() {
        var start = started()
        let refreshes = run(&start, from: 1, to: 61).filter { $0.1 == .refresh }.map(\.0)
        XCTAssertEqual(refreshes, [30, 60], "read again every refreshEvery")
    }

    func testNothingIsWarmedOnBatteryHeatLowDataModeOrNoNetwork() {
        let held: [(LiveWarmStart.Conditions, LiveWarmStart.Hold)] = [
            (.init(conversation: 7, lowPower: true), .lowPower),
            (.init(conversation: 7, hot: true), .thermal),
            (.init(conversation: 7, constrained: true), .constrained),
            (.init(conversation: 7, online: false), .offline),
            (.init(conversation: nil), .noConversation),
            (.init(conversation: 7, conversationReady: false), .conversationNotReady),
            (.init(callActive: true, conversation: 7), .callActive),
        ]
        for (conditions, hold) in held {
            var start = LiveWarmStart()
            _ = start.activate(at: 0)
            XCTAssertEqual(start.update(conditions, at: 0), [], "\(hold)")
            XCTAssertEqual(start.hold, hold)
            var warm = started()
            XCTAssertEqual(warm.update(conditions, at: 10), [.close(hold == .callActive ? .callStarted : .held)], "\(hold) closes a warm one")
        }
    }

    func testTheOpenConversationMovingWarmsTheNewOne() {
        var start = started()
        XCTAssertEqual(start.update(.init(conversation: 9), at: 30), [.close(.conversationMoved), .mint(conversation: 9)])
        XCTAssertEqual(start.conversation, 9)
        XCTAssertEqual(start.phase, .warming)
    }

    // MARK: - Keeping it warm

    func testAWarmConnectionIsPingedEveryHeartbeatAndNothingElse() {
        var start = started(at: 0)
        let actions = run(&start, from: 1, to: 120)
        XCTAssertEqual(actions.filter { $0.1 == .ping }.map(\.0), [21, 41, 61, 81, 101])
        XCTAssertEqual(Set(actions.map { "\($0.1)" }), ["ping", "refresh"])
        XCTAssertEqual(start.phase, .warm)
    }

    func testAConnectionThatStopsAnsweringIsClosedAndWarmedAgainAfterABackoff() {
        var start = started(at: 0)
        let actions = run(&start, from: 1, to: 100, pongs: false)
        let closed = actions.first { $0.1 == .close(.silent) }
        XCTAssertEqual(closed?.0, 72, "dead once nothing is heard for deadAfter")
        XCTAssertEqual(actions.first { if case .mint = $0.1 { return true } else { return false } }?.0, 77, "the first backoff is 5 s")
    }

    func testAWarmUpThatNeverHearsSessionCreatedTimesOut() {
        var start = started(at: 0, warm: false)
        let actions = run(&start, from: 1, to: 17)
        XCTAssertEqual(actions.filter { $0.1 == .close(.timedOut) }.map(\.0), [16])
        XCTAssertEqual(start.hold, .backingOff)
    }

    func testFailuresBackOffLongerEachTimeAndASuccessResetsIt() {
        var start = started(at: 0, warm: false)
        var mints: [TimeInterval] = [0]
        var now: TimeInterval = 0.5
        for _ in 0..<4 {
            XCTAssertEqual(start.failed(at: now), [.close(.failed)])
            while true {
                now += 1
                if start.tick(at: now).contains(where: { if case .mint = $0 { return true } else { return false } }) { break }
            }
            mints.append(now)
            now += 0.5
        }
        let waits = zip(mints.dropFirst(), mints).map { $0 - $1 }
        XCTAssertEqual(waits.map { $0.rounded() }, [6, 16, 61, 121], "5, 15, 60, 120 s, to the next whole tick")
        start.ready(at: now)
        XCTAssertEqual(start.failed(at: now + 1), [.close(.failed)])
        XCTAssertEqual(start.tick(at: now + 7).contains(.mint(conversation: 7)), true, "back to the first wait")
    }

    func testAWarmConnectionIsReplacedAtMaxAgeAndTheBudgetEndsIt() {
        var start = started(at: 0)
        var mints = 1
        var now: TimeInterval = 1
        while now < 10_000 {
            for action in start.tick(at: now) {
                if action == .ping { start.heard(at: now) }
                if case .mint = action {
                    mints += 1
                    start.ready(at: now + 0.5)
                }
            }
            now += 1
        }
        XCTAssertEqual(mints, LiveWarmStart.warmsPerVisit)
        XCTAssertEqual(start.hold, .budgetSpent)
        XCTAssertEqual(start.phase, .idle)
    }

    func testASuspendedAppPingsAndRefreshesTheMomentItWakes() {
        var start = started(at: 0)
        _ = start.tick(at: 1)
        XCTAssertEqual(start.tick(at: 9), [.refresh, .ping], "a gap longer than longestTickGap")
    }

    // MARK: - The tap

    func testATapOnTheWarmConversationClaimsItOnce() {
        var start = started(at: 0)
        run(&start, from: 1, to: 50)
        XCTAssertEqual(start.claim(7, at: 50.5), .warm(age: 49.5))
        XCTAssertEqual(start.phase, .idle)
        XCTAssertEqual(start.claim(7, at: 50.6), .cold(.none), "a connection is handed over once")
        XCTAssertEqual(start.callStarted(at: 50.7), [], "the claimed one is the call's: nothing to close")
    }

    func testATapThatFindsNothingUsableStartsCold() {
        var warming = started(at: 0, warm: false)
        XCTAssertEqual(warming.claim(7, at: 2), .cold(.warming))
        XCTAssertEqual(warming.callStarted(at: 2), [.close(.callStarted)], "the one still warming is dropped")

        var other = started(at: 0)
        XCTAssertEqual(other.claim(8, at: 2), .cold(.otherConversation))
        XCTAssertEqual(other.callStarted(at: 2), [.close(.callStarted)])

        var stale = started(at: 0)
        XCTAssertEqual(stale.claim(7, at: 47), .cold(.stale), "nothing heard since the warm-up, 46 s ago")

        var old = started(at: 0)
        var now: TimeInterval = 1
        while now < 300 { old.heard(at: now); now += 1 }
        XCTAssertEqual(old.claim(7, at: 301.5), .cold(.tooOld))
    }

    func testAfterACallTheNextOneIsWarmedAgain() {
        var start = started(at: 0)
        _ = start.claim(7, at: 5)
        _ = start.callStarted(at: 5)
        XCTAssertEqual(run(&start, from: 6, to: 200).filter { if case .mint = $0.1 { return true } else { return false } }.count, 0,
                       "nothing warms while a call is up")
        XCTAssertEqual(start.callEnded(at: 201), [.refresh])
        XCTAssertEqual(start.update(ready, at: 201.3), [.mint(conversation: 7)])
    }

    func testTheCarLeavingClosesEverything() {
        var start = started(at: 0)
        XCTAssertEqual(start.deactivate(), [.close(.left)])
        XCTAssertEqual(start.tick(at: 60), [], "nothing until the car is back")
        XCTAssertEqual(start.update(ready, at: 61), [])
        XCTAssertEqual(start.claim(7, at: 62), .cold(.none))
    }

    // MARK: - New

    /// New's connection is held on the conversation Zimmer keeps ready, beside the open one's.
    private func newStarted(engine: LiveWarmStart.Engine = .gptLive, life: TimeInterval? = nil) -> LiveWarmStart {
        var start = LiveWarmStart(.new)
        XCTAssertEqual(start.activate(at: 0), [.refresh])
        XCTAssertEqual(start.update(.init(conversation: 30), at: 0.3), [.mint(conversation: 30)])
        start.connecting(engine)
        start.ready(at: 1, life: life)
        return start
    }

    func testNewIsHeldThroughACallSoTheNewThatEndsItIsReady() {
        var start = newStarted()
        run(&start, from: 2, to: 10)
        XCTAssertEqual(start.callStarted(at: 10), [], "Continue's call is no reason to let New's go")
        XCTAssertEqual(start.update(.init(callActive: true, conversation: 30), at: 11), [])
        XCTAssertEqual(start.phase, .warm)
        XCTAssertEqual(start.claim(30, at: 11), .warm(age: 10))
    }

    func testATakenNewLeavesNothingToBeReadyForUntilZimmerKeepsAnother() {
        var start = newStarted()
        XCTAssertEqual(start.claim(30, at: 5), .warm(age: 4))
        XCTAssertEqual(start.callStarted(at: 5), [], "and nothing is opened on the conversation the call is on")
        XCTAssertFalse(run(&start, from: 6, to: 60).contains { if case .mint = $0.1 { return true } else { return false } })
        XCTAssertEqual(start.taken(at: 61), [.refresh], "Zimmer answered the tap")
        XCTAssertEqual(start.update(.init(callActive: true, conversation: 31), at: 61.5), [.mint(conversation: 31)], "ready again, with the call still up")
    }

    func testNewIsAskedForRarelyAndAgainSoonAfterAFailure() {
        var start = newStarted()
        XCTAssertFalse(run(&start, from: 2, to: 500).contains { $0.1 == .refresh }, "nothing but a tap changes it")
        start.refreshFailed(at: 500)
        XCTAssertEqual(run(&start, from: 501, to: 540).filter { $0.1 == .refresh }.map(\.0), [530])
    }

    // MARK: - GPT-Live

    /// A session on its way up is seconds ahead of one started at the tap, so the tap takes it. A
    /// Realtime socket that has not said `session.created` has nothing on it yet.
    func testAGptLiveSessionOnItsWayUpIsTakenAndARealtimeOneIsNot() {
        for (engine, claim) in [(LiveWarmStart.Engine.gptLive, LiveWarmStart.Claim.warming(age: 2)), (.realtime, .cold(.warming))] {
            var start = LiveWarmStart(.new)
            _ = start.activate(at: 0)
            _ = start.update(.init(conversation: 30), at: 0)
            start.connecting(engine)
            XCTAssertEqual(start.claim(30, at: 2), claim)
        }
        // Again, after one that was GPT-Live: what the last was is not what this one is.
        var again = newStarted()
        XCTAssertEqual(again.settingsChanged(at: 2), [.close(.settingsChanged), .mint(conversation: 30)])
        XCTAssertEqual(again.claim(30, at: 2.5), .cold(.warming))

        var unasked = LiveWarmStart(.new)
        _ = unasked.activate(at: 0)
        _ = unasked.update(.init(conversation: 30), at: 0)
        XCTAssertEqual(unasked.claim(30, at: 0.2), .cold(.warming), "Zimmer has not said what it would be")
    }

    /// It is billed by the second, so it is held only while a call may be near.
    func testAGptLiveSessionIsLetGoOnceNothingSaysACallIsNearAndHeldAgainWhenSomethingDoes() {
        var start = newStarted()
        let actions = run(&start, from: 2, to: 1_300)
        XCTAssertEqual(actions.filter { $0.1 == .close(.resting) }.map(\.0), [1_200])
        XCTAssertEqual(start.hold, .resting)
        XCTAssertFalse(run(&start, from: 1_301, to: 3_000).contains { if case .mint = $0.1 { return true } else { return false } }, "and nothing is opened meanwhile")
        XCTAssertEqual(start.interest(at: 3_001), [.mint(conversation: 30)], "Zimmer came to the front in the car")
        start.ready(at: 3_003)
        run(&start, from: 3_001, to: 3_010)
        XCTAssertEqual(start.claim(30, at: 3_010), .warm(age: 7))
    }

    func testSomethingSayingACallIsNearKeepsItHeldToItsAge() {
        var start = newStarted()
        run(&start, from: 2, to: 900)
        XCTAssertEqual(start.interest(at: 900), [], "held already")
        let actions = run(&start, from: 901, to: 1_210)
        XCTAssertEqual(actions.filter { $0.1 == .close(.maxAge) }.map(\.0), [1_201])
        XCTAssertTrue(actions.contains { $0.0 == 1_201 && $0.1 == .mint(conversation: 30) }, "replaced, not let go")
    }

    /// Realtime bills by tokens, and an idle socket uses none.
    func testARealtimeConnectionDoesNotRest() {
        var start = newStarted(engine: .realtime)
        let actions = run(&start, from: 2, to: 3_000)
        XCTAssertFalse(actions.contains { $0.1 == .close(.resting) })
        XCTAssertEqual(actions.first { $0.1 == .close(.maxAge) }?.0, 301)
    }

    /// A call that starts on it needs the rest of the session's life to run in.
    func testASessionIsHeldNoLongerThanHalfTheLifeOpenAIGaveIt() {
        var start = newStarted(life: 1_000)
        XCTAssertEqual(run(&start, from: 2, to: 600).first { $0.1 == .close(.maxAge) }?.0, 501)
    }

    /// Suspended, it keeps no ICE consent going: OpenAI has let the session go, or is about to.
    func testAGptLiveSessionIsNotTrustedAfterTheAppWasSuspended() {
        var start = newStarted()
        _ = start.tick(at: 2)
        XCTAssertEqual(start.claim(30, at: 20), .cold(.stale), "a tap before anything ticks")
        XCTAssertEqual(start.tick(at: 20.5), [.refresh, .close(.suspended), .mint(conversation: 30)])
    }

    /// Its instructions are fixed when it starts, so Continue's is made again when the thread moves on.
    func testAGptLiveConnectionFollowsWhatIsInItsConversation() {
        var start = LiveWarmStart(.open)
        _ = start.activate(at: 0)
        _ = start.update(.init(conversation: 7, version: "a"), at: 0)
        start.connecting(.gptLive)
        start.ready(at: 1)
        XCTAssertEqual(start.update(.init(conversation: 7, version: "a"), at: 30), [])
        XCTAssertEqual(start.update(.init(conversation: 7, version: "b"), at: 60), [.close(.conversationChanged), .mint(conversation: 7)])

        var realtime = LiveWarmStart(.open)
        _ = realtime.activate(at: 0)
        _ = realtime.update(.init(conversation: 7, version: "a"), at: 0)
        realtime.connecting(.realtime)
        realtime.ready(at: 1)
        XCTAssertEqual(realtime.update(.init(conversation: 7, version: "b"), at: 60), [], "the tap's session.update brings it up to date")
    }

    func testChangedSettingsAreWhatTheNextTapGets() {
        var start = newStarted()
        XCTAssertEqual(start.settingsChanged(at: 40), [.close(.settingsChanged), .mint(conversation: 30)])
        var backingOff = newStarted()
        _ = backingOff.failed(at: 10)
        XCTAssertEqual(backingOff.settingsChanged(at: 11), [.mint(conversation: 30)], "and what was refused may not be now")
    }

    /// Paid standby is off, or at its cap: one question a conversation, no retries, and the tap starts cold.
    func testARefusalIsAnAnswerNotAFailureToTryAgain() {
        for slot in [LiveWarmStart.Slot.open, .new] {
            var start = LiveWarmStart(slot)
            _ = start.activate(at: 0)
            XCTAssertEqual(start.update(.init(conversation: 30), at: 0.3), [.mint(conversation: 30)])
            XCTAssertEqual(start.refused(), [.close(.refused)])
            XCTAssertEqual(start.phase, .idle)
            let later = run(&start, from: 1, to: 3_000).map(\.1)
            XCTAssertEqual(Set(later.map { "\($0)" }), ["refresh"], "nothing asked for again")
            XCTAssertEqual(start.update(.init(conversation: 30), at: 3_001), [])
            XCTAssertEqual(start.interest(at: 3_002), [])
            XCTAssertEqual(start.hold, .refused)
            XCTAssertEqual(start.claim(30, at: 3_003), .cold(.none))
            XCTAssertEqual(start.warms, 1)

            XCTAssertEqual(start.update(.init(conversation: 31), at: 3_004), [.mint(conversation: 31)], "another conversation is another question")
            XCTAssertEqual(start.refused(), [.close(.refused)])
            XCTAssertEqual(start.settingsChanged(at: 3_005), [.mint(conversation: 31)], "opted in on this phone")
        }
    }

    func testARefusalEndsWithTheVisit() {
        var start = LiveWarmStart(.new)
        _ = start.activate(at: 0)
        _ = start.update(.init(conversation: 30), at: 0)
        _ = start.refused()
        _ = start.deactivate()
        _ = start.activate(at: 100)
        XCTAssertEqual(start.update(.init(conversation: 30), at: 100), [.mint(conversation: 30)])
        XCTAssertEqual(start.refused(), [.close(.refused)])
        XCTAssertEqual(start.refused(), [], "nothing on its way to refuse")
    }

    /// Putting the phone down and picking it up is no new budget.
    func testTheBudgetIsTheHoursNotTheOpenings() {
        var start = LiveWarmStart(.new)
        var mints = 0
        for opening in 0..<40 {
            let now = TimeInterval(opening) * 30
            _ = start.activate(at: now)
            mints += start.update(.init(conversation: 30), at: now).count
            _ = start.deactivate()
        }
        XCTAssertEqual(mints, LiveWarmStart.warmsPerVisit)
        _ = start.activate(at: LiveWarmStart.visitLasts + 1)
        XCTAssertEqual(start.update(.init(conversation: 30), at: LiveWarmStart.visitLasts + 1), [.mint(conversation: 30)])
    }

    func testNothingIsHeldForAPersonWhoIsTyping() {
        for slot in [LiveWarmStart.Slot.open, .new] {
            var start = LiveWarmStart(slot)
            _ = start.activate(at: 0)
            XCTAssertEqual(start.update(.init(conversation: 7, typing: true), at: 0), [])
            XCTAssertEqual(start.hold, .typing)
        }
    }

    // MARK: - The rule

    /// Nothing user-originated and nothing billable goes up a warm connection. The only things a
    /// warm connection can be asked to do are read Zimmer, mint, ping and close — `Action` has no
    /// case that sends on the socket — and over a long, eventful drive it never gets as far as a
    /// call unless `claim` is called, which only the driver's tap does.
    func testAWarmConnectionNeverSendsAnythingAndOnlyATapHandsItToACall() {
        var start = LiveWarmStart()
        var actions = start.activate(at: 0)
        // Seeded, so a failure reproduces: the same drive every run.
        var generator = SeededGenerator(seed: 0x5EED_CA2)
        var now: TimeInterval = 0
        var conversation = 7
        while now < 3_600 {
            now += 1
            actions += start.tick(at: now)
            switch Int.random(in: 0..<40, using: &generator) {
            case 0: actions += start.failed(at: now)
            case 1: conversation += 1; actions += start.update(.init(conversation: conversation), at: now)
            case 2: actions += start.update(.init(conversation: conversation, lowPower: Bool.random(using: &generator), online: Bool.random(using: &generator)), at: now)
            case 3...9: if start.phase == .warming { start.ready(at: now) }
            default: start.heard(at: now)
            }
        }
        // Exhaustive: a case that sent on the socket would have to be added here, on purpose.
        for action in actions {
            switch action {
            case .refresh, .ping, .close, .mint: continue
            }
        }
        XCTAssertTrue(actions.contains { if case .mint = $0 { return true } else { return false } }, "the drive did warm")
        XCTAssertLessThanOrEqual(actions.filter { if case .mint = $0 { return true } else { return false } }.count, LiveWarmStart.warmsPerVisit,
                                 "however eventful the drive, the mints stay within the budget")
    }
}

/// SplitMix64: a small deterministic generator for the randomized drive.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What the pre-warm reads and mints over `/api/v1/live*`.
final class LiveWarmAPITests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    func testTheIndexSaysWhetherTheOpenConversationCanBeMintedOnNow() async throws {
        @Sendable func conversation(_ status: String) -> [String: Any] { [
            "id": 7, "mode": "text", "voice": false, "label": "Live Mode", "mode_label": "Typed", "status": status, "title": "Live Mode",
            "agent_root": "live-mode", "model": "gpt-6-luna", "mcp_servers": ["zimmer"], "responding": false,
        ] }
        let (api, _) = client([
            { _ in Fixtures.json(200, ["live_conversations": [conversation("active")], "current_id": 7]) },
            { _ in Fixtures.json(200, ["live_conversations": [conversation("preparing")], "current_id": 7]) },
        ])
        let active = try await api.liveConversations()
        XCTAssertTrue(active.currentIsReady, "active, so a secret can be minted on it")
        let preparing = try await api.liveConversations()
        XCTAssertFalse(preparing.currentIsReady, "still reading its instructions")
    }

    func testThePrewarmMintSaysSoAndAsksForItsOwnReplies() async throws {
        let (api, transport) = client([{ _ in
            Fixtures.json(200, ["client_secret": "ek_warm", "model": "gpt-realtime-2.1-mini", "listening": "always",
                                "websocket_url": "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini"])
        }])
        let grant = try await api.livePrewarmGrant(7)
        XCTAssertEqual(grant.realtime?.clientSecret, "ek_warm")
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/live_conversations/7/client_secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent.first?.body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["prewarm"] as? String, "1")
        XCTAssertEqual(body["standby"] as? String, "1", "this app can hold a GPT-Live session")
        XCTAssertEqual(body["listening_modes"] as? String, "1")
    }

    func testNewIsKeptReadyHeldInStandbyAndTaken() async throws {
        @Sendable func conversation(_ status: String) -> [String: Any] { [
            "id": 30, "mode": "voice", "voice": true, "label": "Live Mode", "mode_label": "Spoken", "status": status, "title": "Live Mode",
            "agent_root": "live-mode", "model": "gpt-live-1", "mcp_servers": ["zimmer"], "responding": false, "last_activity_at": "2026-11-24T15:00:00Z",
        ] }
        let (api, transport) = client([
            { _ in Fixtures.json(200, conversation("standby")) },
            { _ in Fixtures.json(200, ["engine": "gpt_live_claude", "model": "gpt-live-1"]) },
            { _ in Fixtures.json(200, ["session_id": "live_1", "sdp": "v=0 answer", "model": "gpt-live-1"]) },
            { _ in Fixtures.json(201, conversation("active")) },
        ])
        func body(_ index: Int) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[index].body ?? Data()) as? [String: Any])
        }

        let standby = try await api.liveStandby()
        XCTAssertEqual(transport.sent[0].url.path, "/api/v1/live_conversations/standby")
        XCTAssertEqual(standby.status, .standby)
        XCTAssertFalse(standby.status.isOpen)
        XCTAssertEqual(standby.lastActivityAt, "2026-11-24T15:00:00Z")
        XCTAssertEqual(standby.asStarted.status, .active, "what its screen shows from the tap")
        XCTAssertEqual(standby.asStarted.mode, .voice)

        let grant = try await api.livePrewarmGrant(standby.id)
        XCTAssertTrue(grant.isGptLive)
        _ = try await api.startGptLiveSession(standby.id, sdp: "v=0 offer", standby: true)
        XCTAssertEqual(try body(2)["standby"] as? String, "1")

        let started = try await api.startLiveConversation(.voice, standby: standby.id, again: false)
        XCTAssertEqual(transport.sent[3].url.path, "/api/v1/live_conversations")
        XCTAssertEqual(try body(3)["standby_id"] as? Int, 30)
        XCTAssertEqual(started.status, .active)
        XCTAssertEqual(started.asStarted, started)
    }

    /// The fake keeps the server's rules: one kept ready, on no list, taken once.
    func testTheFakeKeepsOneReadyAndNewTakesIt() async throws {
        let fake = FakeZimmerAPI()
        let kept = try await fake.liveStandby()
        let again = try await fake.liveStandby()
        XCTAssertEqual(kept, again)
        let before = try await fake.liveConversations()
        XCTAssertFalse(before.conversations.contains { $0.id == kept.id })
        XCTAssertEqual(before.current, 21, "asking ends nothing")
        let started = try await fake.startLiveConversation(.voice, standby: kept.id, again: false)
        XCTAssertEqual(started.id, kept.id)
        let repeated = try await fake.startLiveConversation(.voice, standby: kept.id, again: true)
        XCTAssertEqual(repeated.id, kept.id, "the same tap, asked again")
        let after = try await fake.liveConversations()
        XCTAssertEqual(after.current, kept.id)
        let next = try await fake.liveStandby()
        XCTAssertNotEqual(next.id, kept.id)
    }

    func testTheTapsSessionUpdateRecordsTheWarmModelAndAPlainOneDoesNot() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, ["session": ["type": "realtime"]]) },
            { _ in Fixtures.json(200, ["session": ["type": "realtime"]]) },
        ])
        _ = try await api.liveSessionUpdate(7, recordingModel: "gpt-realtime-2.1-mini")
        _ = try await api.liveSessionUpdate(7)
        let warm = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[0].body ?? Data()) as? [String: Any])
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[1].body ?? Data()) as? [String: Any])
        XCTAssertEqual(warm["model"] as? String, "gpt-realtime-2.1-mini")
        XCTAssertNil(plain["model"])
        XCTAssertEqual(plain["listening_modes"] as? String, "1")
    }

    /// The fake keeps the server's rules: nothing on the conversation changes, the mode included,
    /// and an ended conversation is refused.
    func testThePrewarmMintChangesNothingOnTheConversation() async throws {
        let fake = FakeZimmerAPI()
        let overview = try await fake.liveConversations()
        let current = try XCTUnwrap(overview.current)
        let before = try await fake.liveConversation(current, afterTurn: nil)
        _ = try await fake.livePrewarmGrant(current)
        let after = try await fake.liveConversation(current, afterTurn: nil)
        XCTAssertEqual(after, before)
        _ = try await fake.finishLiveConversation(current)
        do {
            _ = try await fake.livePrewarmGrant(current)
            XCTFail("an ended conversation is refused")
        } catch let ZimmerError.http(status, _) {
            XCTAssertEqual(status, 409)
        }
        let mints = await fake.prewarmMints
        XCTAssertEqual(mints, 1)
    }
}
