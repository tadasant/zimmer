import XCTest
@testable import ZimmerKit

/// CarPlay pre-warm's rules (`LiveWarmStart`): when a connection is warmed, kept, replaced and
/// dropped, what a tap gets, and the rule the whole feature stands on — nothing goes up a warm
/// connection before the driver taps.
final class LiveWarmStartTests: XCTestCase {
    private let ready = LiveWarmStart.Conditions(flagOn: true, conversation: 7)

    /// Connected, refreshed with `conditions`, and (unless `warm` is false) warm at `at`.
    private func started(_ conditions: LiveWarmStart.Conditions? = nil, at: TimeInterval = 0, warm: Bool = true) -> LiveWarmStart {
        var start = LiveWarmStart()
        XCTAssertEqual(start.carConnected(at: at), [.refresh])
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
        XCTAssertEqual(start.carConnected(at: 0), [.refresh])
        XCTAssertEqual(start.update(ready, at: 0.3), [.mint(conversation: 7)])
        XCTAssertEqual(start.phase, .warming)
        start.ready(at: 1.2)
        XCTAssertEqual(start.phase, .warm)
        XCTAssertEqual(start.conversation, 7)
        XCTAssertEqual(start.update(ready, at: 2), [], "a refresh that changes nothing changes nothing")
    }

    func testTheFlagOffWarmsNothingAndTurningItOffClosesTheWarmConnection() {
        var off = LiveWarmStart()
        _ = off.carConnected(at: 0)
        XCTAssertEqual(off.update(.init(flagOn: false, conversation: 7), at: 0), [])
        XCTAssertEqual(off.hold, .flagOff)
        XCTAssertEqual(off.claim(7, at: 5), .cold(.none))
        XCTAssertEqual(run(&off, from: 1, to: 600).count, 0, "off reads nothing more until the car reconnects or a call ends")
        XCTAssertEqual(off.callEnded(at: 601), [.refresh])

        var start = started()
        XCTAssertEqual(start.update(.init(flagOn: false, conversation: 7), at: 40), [.close(.held)], "the kill switch")
        XCTAssertEqual(start.phase, .idle)
        XCTAssertEqual(start.hold, .flagOff)
    }

    func testTheKillSwitchReachesAWarmConnectionWithinOneRefresh() {
        var start = started()
        let refreshes = run(&start, from: 1, to: 31).filter { $0.1 == .refresh }.map(\.0)
        XCTAssertEqual(refreshes, [30], "read again every refreshEvery")
        XCTAssertEqual(start.update(.init(flagOn: false, conversation: 7), at: 30.2), [.close(.held)])
    }

    func testNothingIsWarmedOnBatteryHeatLowDataModeOrNoNetwork() {
        let held: [(LiveWarmStart.Conditions, LiveWarmStart.Hold)] = [
            (.init(flagOn: true, conversation: 7, lowPower: true), .lowPower),
            (.init(flagOn: true, conversation: 7, hot: true), .thermal),
            (.init(flagOn: true, conversation: 7, constrained: true), .constrained),
            (.init(flagOn: true, conversation: 7, online: false), .offline),
            (.init(flagOn: true, conversation: nil), .noConversation),
            (.init(flagOn: true, conversation: 7, conversationReady: false), .conversationNotReady),
            (.init(flagOn: true, callActive: true, conversation: 7), .callActive),
        ]
        for (conditions, hold) in held {
            var start = LiveWarmStart()
            _ = start.carConnected(at: 0)
            XCTAssertEqual(start.update(conditions, at: 0), [], "\(hold)")
            XCTAssertEqual(start.hold, hold)
            var warm = started()
            XCTAssertEqual(warm.update(conditions, at: 10), [.close(hold == .callActive ? .callStarted : .held)], "\(hold) closes a warm one")
        }
    }

    func testTheOpenConversationMovingWarmsTheNewOne() {
        var start = started()
        XCTAssertEqual(start.update(.init(flagOn: true, conversation: 9), at: 30), [.close(.conversationMoved), .mint(conversation: 9)])
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
        let actions = run(&start, from: 1, to: 12)
        XCTAssertEqual(actions.filter { $0.1 == .close(.timedOut) }.map(\.0), [11])
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
        XCTAssertEqual(mints, LiveWarmStart.warmsPerDrive)
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
        XCTAssertEqual(start.carDisconnected(), [.close(.carLeft)])
        XCTAssertEqual(start.tick(at: 60), [], "nothing until the car is back")
        XCTAssertEqual(start.update(ready, at: 61), [])
        XCTAssertEqual(start.claim(7, at: 62), .cold(.none))
    }

    // MARK: - The rule

    /// Nothing user-originated and nothing billable goes up a warm connection. The only things a
    /// warm connection can be asked to do are read Zimmer, mint, ping and close — `Action` has no
    /// case that sends on the socket — and over a long, eventful drive it never gets as far as a
    /// call unless `claim` is called, which only the driver's tap does.
    func testAWarmConnectionNeverSendsAnythingAndOnlyATapHandsItToACall() {
        var start = LiveWarmStart()
        var actions = start.carConnected(at: 0)
        var generator = SystemRandomNumberGenerator()
        var now: TimeInterval = 0
        var conversation = 7
        while now < 3_600 {
            now += 1
            actions += start.tick(at: now)
            switch Int.random(in: 0..<40, using: &generator) {
            case 0: actions += start.failed(at: now)
            case 1: conversation += 1; actions += start.update(.init(flagOn: true, conversation: conversation), at: now)
            case 2: actions += start.update(.init(flagOn: Bool.random(using: &generator), conversation: conversation, lowPower: Bool.random(using: &generator)), at: now)
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
        XCTAssertTrue(actions.contains(.ping))
        XCTAssertLessThanOrEqual(actions.filter { if case .mint = $0 { return true } else { return false } }.count, LiveWarmStart.warmsPerDrive,
                                 "however eventful the drive, the mints stay within the budget")
    }
}

/// What the pre-warm reads and mints over `/api/v1/live*`.
final class LiveWarmAPITests: XCTestCase {
    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    func testTheIndexCarriesTheFlagAndAnOlderServerReadsAsOff() async throws {
        @Sendable func conversation() -> [String: Any] { [
            "id": 7, "mode": "text", "voice": false, "label": "Live Mode", "mode_label": "Typed", "status": "active", "title": "Live Mode",
            "agent_root": "live-mode", "model": "gpt-6-luna", "mcp_servers": ["zimmer"], "responding": false,
        ] }
        let (api, _) = client([
            { _ in Fixtures.json(200, ["live_conversations": [conversation()], "current_id": 7, "prewarm": ["carplay": true]]) },
            { _ in Fixtures.json(200, ["live_conversations": [conversation()], "current_id": 7]) },
        ])
        let on = try await api.liveConversations()
        XCTAssertTrue(on.carplayPrewarm)
        XCTAssertTrue(on.currentIsReady, "active, so a secret can be minted on it")
        let older = try await api.liveConversations()
        XCTAssertFalse(older.carplayPrewarm)
    }

    func testThePrewarmMintSaysSoAndAsksForItsOwnReplies() async throws {
        let (api, transport) = client([{ _ in
            Fixtures.json(200, ["client_secret": "ek_warm", "model": "gpt-realtime-2.1-mini", "listening": "always",
                                "websocket_url": "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini"])
        }])
        let secret = try await api.livePrewarmSecret(7)
        XCTAssertEqual(secret.clientSecret, "ek_warm")
        XCTAssertEqual(transport.sent.first?.url.path, "/api/v1/live_conversations/7/client_secret")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent.first?.body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["prewarm"] as? String, "1")
        XCTAssertEqual(body["listening_modes"] as? String, "1")
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

    /// The fake keeps the server's rules: refused while the flag is off, and nothing on the
    /// conversation changes when it is on — the mode included.
    func testThePrewarmMintIsRefusedWhileOffAndChangesNothingWhenOn() async throws {
        let fake = FakeZimmerAPI()
        let overview = try await fake.liveConversations()
        let current = try XCTUnwrap(overview.current)
        do {
            _ = try await fake.livePrewarmSecret(current)
            XCTFail("refused while off")
        } catch let ZimmerError.http(status, _) {
            XCTAssertEqual(status, 403)
        }
        await fake.setCarplayPrewarm(true)
        let before = try await fake.liveConversation(current, afterTurn: nil)
        let flagged = try await fake.liveConversations()
        XCTAssertTrue(flagged.carplayPrewarm)
        _ = try await fake.livePrewarmSecret(current)
        let after = try await fake.liveConversation(current, afterTurn: nil)
        XCTAssertEqual(after, before)
        let mints = await fake.prewarmMints
        XCTAssertEqual(mints, 1)
    }
}
